defmodule DarkZenith.Packages do
  @moduledoc """
  The Packages context (DESIGN.md: Data Model — Packages; REST API —
  Packages): reads with the documented filters and EVR-aware sorts, and the
  package deletion transaction. Creation happens in the upload pipeline.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.Authorization
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Rpm.Metadata

  ## Reads

  @doc "Fetches a package by id scoped to the repository, or nil."
  def get_package(%Repository{id: repository_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Package, id: uuid, repository_id: repository_id)
      :error -> nil
    end
  end

  @doc """
  The package list query with the documented filters and sorts (DESIGN.md:
  API Contract Details). `opts`: `:q` (substring on name/summary), `:name`,
  `:arch` (exact), `:sort` (`name`/`version`/`arch`/`inserted_at`, `-`
  prefix for descending; nil for the default ordering).
  """
  def list_query(repository_id, opts \\ []) do
    base = from p in Package, where: p.repository_id == ^repository_id

    base
    |> filter_q(opts[:q])
    |> filter_eq(:name, opts[:name])
    |> filter_eq(:arch, opts[:arch])
    |> sort(opts[:sort])
  end

  defp filter_q(query, nil), do: query

  defp filter_q(query, q) do
    pattern = "%" <> escape_like(q) <> "%"

    from p in query,
      where:
        fragment("? ILIKE ? ESCAPE '\\'", p.name, ^pattern) or
          fragment("? ILIKE ? ESCAPE '\\'", p.summary, ^pattern)
  end

  # %, _, and the escape character are literal in user input.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, field, value), do: from(p in query, where: field(p, ^field) == ^value)

  # Default: name asc, arch asc, RPM EVR desc, id asc.
  defp sort(query, nil) do
    from p in query,
      order_by: [
        asc: p.name,
        asc: p.arch,
        desc: fragment("ROW(?, ?, ?)::dark_zenith_rpm_evr", p.epoch, p.version, p.release),
        asc: p.id
      ]
  end

  # `version` orders by EVR with name/arch/id ascending tie-breakers;
  # `-version` reverses only the EVR ordering.
  defp sort(query, {:version, direction}) do
    evr = dynamic([p], fragment("ROW(?, ?, ?)::dark_zenith_rpm_evr", p.epoch, p.version, p.release))

    from p in query,
      order_by: ^[{direction, evr}, asc: dynamic([p], p.name), asc: dynamic([p], p.arch), asc: dynamic([p], p.id)]
  end

  # Other sorts reverse only the named column; id ascending is the only
  # tie-breaker.
  defp sort(query, {field, direction}) do
    from p in query, order_by: ^[{direction, dynamic([p], field(p, ^field))}, asc: dynamic([p], p.id)]
  end

  ## Deletion

  @doc """
  Deletes a package in one transaction (DESIGN.md: Package Upload &
  Processing): locks the owner, repository, and package in the global
  order; decrements the metadata counters and the owner's `storage_bytes`;
  increments `metadata_revision`; and enqueues metadata regeneration plus
  version-aware B2 deletion.
  """
  def delete_package(%User{} = actor, %Repository{} = repository, %Package{} = package) do
    with :ok <- authorize(actor, repository) do
      {:ok, result} =
        Repo.transact(fn ->
          Repo.one!(from u in User, where: u.id == ^repository.user_id, lock: "FOR UPDATE")

          repo =
            Repo.one!(from r in Repository, where: r.id == ^repository.id, lock: "FOR UPDATE")

          case Repo.one(
                 from p in Package,
                   where: p.id == ^package.id and p.repository_id == ^repository.id,
                   lock: "FOR UPDATE"
               ) do
            nil ->
              {:ok, {:error, :not_found}}

            current ->
              entry_sizes = Repodata.entry_open_sizes(current)
              overhead_now = Repodata.document_overhead(repo.package_count)
              overhead_next = Repodata.document_overhead(repo.package_count - 1)

              Repo.delete!(current)

              {1, _} =
                Repo.update_all(
                  from(r in Repository, where: r.id == ^repo.id),
                  inc: [
                    package_count: -1,
                    metadata_revision: 1,
                    primary_open_bytes:
                      -entry_sizes.primary + overhead_next.primary - overhead_now.primary,
                    filelists_open_bytes:
                      -entry_sizes.filelists + overhead_next.filelists - overhead_now.filelists,
                    other_open_bytes:
                      -entry_sizes.other + overhead_next.other - overhead_now.other
                  ]
                )

              {1, _} =
                Repo.update_all(
                  from(u in User, where: u.id == ^repo.user_id),
                  inc: [storage_bytes: -current.size_package]
                )

              Audit.record!("package.delete",
                actor: actor,
                target: {:package, current.id},
                metadata: %{
                  "slug" => repo.slug,
                  "nevra" =>
                    "#{current.name}-#{current.epoch}:#{current.version}-#{current.release}." <>
                      current.arch
                }
              )

              Repodata.enqueue_regeneration(repo.id)

              %{storage_path: current.storage_path, version_id: current.storage_version_id}
              |> DarkZenith.Workers.FinalVersionCleanup.new()
              |> Oban.insert!()

              {:ok, :ok}
          end
        end)

      result
    end
  end

  defp authorize(actor, repository) do
    if Authorization.can_manage?(actor, repository), do: :ok, else: {:error, :forbidden}
  end

  @doc """
  Package-row attributes extracted from parsed RPM metadata. The caller adds
  the storage/identity fields the parser cannot know (`sha256`,
  `size_package`, `storage_path`, `storage_version_id`, `repository_id`).
  """
  def metadata_attrs(%Metadata{} = m) do
    %{
      rpm_format: m.rpm_format,
      name: m.name,
      epoch: m.epoch,
      version: m.version,
      release: m.release,
      arch: m.arch,
      summary: m.summary,
      description: m.description,
      url: m.url,
      license: m.license,
      size_installed: m.size_installed,
      size_archive: m.size_archive,
      build_time: m.build_time,
      rpm_sourcerpm: m.rpm_sourcerpm,
      rpm_sourcenevr: m.rpm_sourcenevr,
      rpm_group: m.rpm_group,
      rpm_vendor: m.rpm_vendor,
      rpm_buildhost: m.rpm_buildhost,
      header_start: m.header_start,
      header_end: m.header_end,
      requires: m.requires,
      provides: m.provides,
      conflicts: m.conflicts,
      obsoletes: m.obsoletes,
      recommends: m.recommends,
      suggests: m.suggests,
      supplements: m.supplements,
      enhances: m.enhances,
      files: m.files,
      changelogs: m.changelogs
    }
  end

  @doc """
  All packages of a repository in the deterministic snapshot order used by
  metadata regeneration: `name`, `epoch`, `version`, `release`, `arch`, `id`
  (DESIGN.md: Metadata Generation & Storage step 3).
  """
  def snapshot_query(repository_id) do
    from p in Package,
      where: p.repository_id == ^repository_id,
      order_by: [asc: p.name, asc: p.epoch, asc: p.version, asc: p.release, asc: p.arch, asc: p.id]
  end
end
