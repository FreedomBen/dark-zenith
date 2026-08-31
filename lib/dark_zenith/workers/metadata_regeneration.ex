defmodule DarkZenith.Workers.MetadataRegeneration do
  @moduledoc """
  Regenerates one repository's metadata cache (DESIGN.md: Metadata
  Generation & Storage).

  Snapshots the repository revision, counters, and package set in one
  transaction; encodes each artifact incrementally to a mode-0600 temporary
  file (never a whole document in BEAM memory), aborting if a byte count
  exceeds the effective ceiling `max(MAX_REPODATA_OPEN_BYTES, maintained
  counter)` or differs from the maintained counter; streams gzip (level 6,
  mtime 0, no filename) to a second temporary file; then stores the blobs
  behind a strictly-greater `source_revision` compare-and-swap. Jobs are
  unique per repository while available/scheduled, and a final reload
  re-enqueues when the revision moved past the captured snapshot.
  """

  use Oban.Worker,
    queue: :metadata,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:repository_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Packages
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repodata.{Filelists, Other, Primary, Repomd}
  alias DarkZenith.Repositories.{MetadataCache, Repository}
  alias DarkZenith.Signing
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repository_id" => repository_id}} = job) do
    case snapshot(repository_id) do
      {:ok, :absent} ->
        :ok

      {:ok, :current} ->
        :ok

      {:ok, repository, packages} ->
        with {:error, _} = error <- regenerate(repository, packages) do
          record_exhaustion(job, repository_id)
          error
        end

      {:error, _} = error ->
        record_exhaustion(job, repository_id)
        error
    end
  end

  # The twentieth failed regeneration attempt marks the owner's unresolved
  # user-wide transition failed so a permanently stale cache stays visible
  # outside Oban retention (DESIGN.md: Key replacement step 7).
  defp record_exhaustion(%Oban.Job{attempt: attempt, max_attempts: max}, repository_id)
       when attempt >= max do
    DarkZenith.SigningTransitions.UserWide.record_regeneration_exhaustion(repository_id)
  end

  defp record_exhaustion(_job, _repository_id), do: :ok

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  # Step 3: one transaction, one consistent snapshot.
  defp snapshot(repository_id) do
    Repo.transact(fn ->
      set_snapshot_isolation()

      case Repo.get(Repository, repository_id) do
        nil ->
          {:ok, :absent}

        %Repository{} = repository ->
          cache_revision =
            Repo.one(
              from c in MetadataCache,
                where: c.repository_id == ^repository.id,
                select: c.source_revision
            )

          if cache_revision && cache_revision >= repository.metadata_revision do
            {:ok, :current}
          else
            {:ok, {repository, Repo.all(Packages.snapshot_query(repository.id))}}
          end
      end
    end)
    |> case do
      {:ok, :absent} -> {:ok, :absent}
      {:ok, :current} -> {:ok, :current}
      {:ok, {repository, packages}} -> {:ok, repository, packages}
      {:error, _} = error -> error
    end
  end

  defp regenerate(repository, packages) do
    tmp_dir =
      Path.join(
        rpm_upload_tmpdir(),
        "dz-metadata-#{repository.id}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    File.chmod!(tmp_dir, 0o700)

    try do
      with {:ok, artifacts} <- encode_artifacts(repository, packages, tmp_dir),
           {:ok, repomd_xml, repomd_xml_asc} <- build_repomd(repository, artifacts),
           :ok <- store(repository, artifacts, repomd_xml, repomd_xml_asc) do
        maybe_reenqueue(repository)
        :ok
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  ## Step 4: incremental encoding with counter/ceiling enforcement

  defp encode_artifacts(repository, packages, tmp_dir) do
    [primary: Primary, filelists: Filelists, other: Other]
    |> Enum.reduce_while({:ok, []}, fn {type, encoder}, {:ok, acc} ->
      counter = maintained_counter(repository, type)
      ceiling = max(max_repodata_open_bytes(), counter)

      case encode_artifact(type, encoder, packages, tmp_dir, counter, ceiling) do
        {:ok, artifact} -> {:cont, {:ok, [{type, artifact} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp encode_artifact(type, encoder, packages, tmp_dir, counter, ceiling) do
    open_path = Path.join(tmp_dir, "#{type}.xml")
    gz_path = Path.join(tmp_dir, "#{type}.xml.gz")

    chunks =
      Stream.concat([
        [encoder.prologue(length(packages))],
        Stream.map(packages, &encoder.entry/1),
        [encoder.epilogue()]
      ])

    with {:ok, open_size, open_checksum} <- write_stream(open_path, chunks, ceiling),
         :ok <- check_counter(open_size, counter),
         {:ok, size, checksum} <- write_gzip(open_path, gz_path) do
      {:ok,
       %{
         compressed: File.read!(gz_path),
         open_size: open_size,
         open_checksum: open_checksum,
         size: size,
         checksum: checksum
       }}
    end
  end

  defp write_stream(path, chunks, ceiling) do
    file = File.open!(path, [:write, :binary])
    File.chmod!(path, 0o600)

    result =
      Enum.reduce_while(chunks, {0, :crypto.hash_init(:sha256)}, fn chunk, {size, hash} ->
        data = IO.iodata_to_binary(chunk)
        size = size + byte_size(data)

        if size > ceiling do
          {:halt, {:error, :metadata_limit_exceeded}}
        else
          IO.binwrite(file, data)
          {:cont, {size, :crypto.hash_update(hash, data)}}
        end
      end)

    File.close(file)

    case result do
      {:error, _} = error -> error
      {size, hash} -> {:ok, size, Base.encode16(:crypto.hash_final(hash), case: :lower)}
    end
  end

  defp check_counter(actual, maintained) when actual == maintained, do: :ok
  defp check_counter(_actual, _maintained), do: {:error, :metadata_counter_mismatch}

  defp write_gzip(open_path, gz_path) do
    file = File.open!(gz_path, [:write, :binary])
    File.chmod!(gz_path, 0o600)
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, 6, :deflated, 31, 8, :default)

      {size, hash} =
        open_path
        |> File.stream!(65_536)
        |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn chunk, acc ->
          write_compressed(file, :zlib.deflate(z, chunk), acc)
        end)

      {size, hash} = write_compressed(file, :zlib.deflate(z, <<>>, :finish), {size, hash})
      :ok = :zlib.deflateEnd(z)
      {:ok, size, Base.encode16(:crypto.hash_final(hash), case: :lower)}
    after
      :zlib.close(z)
      File.close(file)
    end
  end

  defp write_compressed(file, iodata, {size, hash}) do
    data = IO.iodata_to_binary(iodata)
    IO.binwrite(file, data)
    {size + byte_size(data), :crypto.hash_update(hash, data)}
  end

  ## Steps 5–6: repomd, optional signature, and the CAS store

  defp build_repomd(repository, artifacts) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix()

    artifacts =
      Enum.map(artifacts, fn {type, artifact} ->
        {type, Map.put(artifact, :timestamp, timestamp)}
      end)

    repomd_xml =
      IO.iodata_to_binary(Repomd.encode(artifacts, repository.metadata_revision))

    if repository.gpg_key_fingerprint do
      owner = Repo.get!(User, repository.user_id)

      case Signing.sign_repomd(owner, repomd_xml) do
        {:ok, armored} ->
          {:ok, repomd_xml, armored}

        {:error, :unavailable} ->
          {:error, :signing_unavailable}

        {:error, :expired} ->
          # Non-retryable: the cache stays at its previous revision and the
          # newer revision keeps returning metadata_not_ready until the key
          # is replaced or removed.
          {:cancel, :conflict_gpg_key_expired}
      end
    else
      {:ok, repomd_xml, nil}
    end
  end

  defp store(repository, artifacts, repomd_xml, repomd_xml_asc) do
    fields = [
      primary_xml_gz: artifacts[:primary].compressed,
      filelists_xml_gz: artifacts[:filelists].compressed,
      other_xml_gz: artifacts[:other].compressed,
      repomd_xml: repomd_xml,
      repomd_xml_asc: repomd_xml_asc,
      source_revision: repository.metadata_revision,
      updated_at: DateTime.utc_now(:second)
    ]

    {:ok, _} =
      Repo.transact(fn ->
        case Repo.one(
               from c in MetadataCache,
                 where: c.repository_id == ^repository.id,
                 lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.insert!(
              struct(
                MetadataCache,
                Keyword.put(fields, :repository_id, repository.id)
              )
            )

            {:ok, :written}

          %MetadataCache{source_revision: current} when current >= repository.metadata_revision ->
            # A newer generation won the race; never move backward.
            {:ok, :lost_race}

          %MetadataCache{} = cache ->
            {1, _} =
              Repo.update_all(
                from(c in MetadataCache, where: c.id == ^cache.id),
                set: fields
              )

            {:ok, :written}
        end
      end)

    :ok
  end

  ## Step 7: re-enqueue when the revision moved during generation

  defp maybe_reenqueue(repository) do
    case Repo.one(
           from r in Repository, where: r.id == ^repository.id, select: r.metadata_revision
         ) do
      nil ->
        :ok

      revision when revision > repository.metadata_revision ->
        Repodata.enqueue_regeneration(repository.id)

      _current ->
        :ok
    end
  end

  # Disabled in test, where the SQL sandbox has already begun the outer
  # transaction and Postgres rejects a late SET TRANSACTION.
  defp set_snapshot_isolation do
    if Application.get_env(:dark_zenith, :metadata_snapshot_isolation, true) do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
    end

    :ok
  end

  defp maintained_counter(repository, :primary), do: repository.primary_open_bytes
  defp maintained_counter(repository, :filelists), do: repository.filelists_open_bytes
  defp maintained_counter(repository, :other), do: repository.other_open_bytes

  defp max_repodata_open_bytes do
    Application.get_env(:dark_zenith, :max_repodata_open_bytes, 268_435_456)
  end

  defp rpm_upload_tmpdir do
    Application.get_env(:dark_zenith, :rpm_upload_tmpdir) || System.tmp_dir!()
  end
end
