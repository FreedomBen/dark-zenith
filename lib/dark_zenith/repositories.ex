defmodule DarkZenith.Repositories do
  @moduledoc """
  The Repositories context: repository lifecycle, slug reservations, and the
  repository metadata cache (DESIGN.md: Data Model; Slug Reservations;
  Metadata Generation & Storage).
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.{MetadataCache, Repository, SlugReservation}
  alias DarkZenith.Signing

  ## Reads

  @doc "Gets a repository by its slug, or nil."
  def get_repository_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Repository, slug: slug)
  end

  @doc "Gets a repository by id, raising when absent."
  def get_repository!(id), do: Repo.get!(Repository, id)

  @doc """
  Lists repositories visible to the given user: public repositories for
  everyone, plus the user's own; admins see all repositories. Ordered by slug
  then id (DESIGN.md: API Contract Details default ordering).
  """
  def list_visible_repositories(user) do
    Repo.all(visible_repositories_query(user))
  end

  @doc "The query behind `list_visible_repositories/1`, for pagination."
  def visible_repositories_query(user) do
    base = from r in Repository, order_by: [asc: r.slug, asc: r.id]

    case user do
      nil -> from r in base, where: r.is_public
      %User{is_admin: true} -> base
      %User{id: user_id} -> from r in base, where: r.is_public or r.user_id == ^user_id
    end
  end

  ## Creation

  @doc """
  Creates a repository (DESIGN.md: Slug Reservations; Metadata Generation &
  Storage). In one transaction: locks the owning user row, checks
  `MAX_USER_REPOSITORIES`, conditionally claims or revives the slug
  reservation, inserts the repository, synchronously generates empty metadata,
  and writes the cache row with `source_revision = 0`, so a new empty
  repository serves valid metadata immediately.

  Returns `{:ok, repository}`, `{:error, changeset}`,
  `{:error, :quota_exceeded}`, or `{:error, :signing_unavailable}` when
  metadata signing is requested but the signing infrastructure is not
  available.
  """
  def create_repository(%User{} = owner, attrs) do
    changeset = Repository.create_changeset(%Repository{}, attrs, owner)

    if changeset.valid? do
      repository_id = Ecto.UUID.generate()
      now = DateTime.utc_now(:second)

      Repo.transact(fn ->
        lock_user_row!(owner.id)

        with :ok <- check_repository_quota(owner.id),
             :ok <- claim_slug(changeset, repository_id, owner, now),
             {:ok, generation, repomd_xml_asc} <- generate_initial_metadata(owner, changeset) do
          repository =
            changeset
            |> Ecto.Changeset.put_change(:id, repository_id)
            |> Ecto.Changeset.put_change(:user_id, owner.id)
            |> Ecto.Changeset.put_change(:rpm_signing_state, initial_signing_state(changeset))
            |> Ecto.Changeset.put_change(:primary_open_bytes, generation.open_sizes.primary)
            |> Ecto.Changeset.put_change(:filelists_open_bytes, generation.open_sizes.filelists)
            |> Ecto.Changeset.put_change(:other_open_bytes, generation.open_sizes.other)
            |> Repo.insert!()

          Repo.insert!(%MetadataCache{
            repository_id: repository.id,
            primary_xml_gz: generation.primary_xml_gz,
            filelists_xml_gz: generation.filelists_xml_gz,
            other_xml_gz: generation.other_xml_gz,
            repomd_xml: generation.repomd_xml,
            repomd_xml_asc: repomd_xml_asc,
            source_revision: 0
          })

          Audit.record!("repository.create",
            actor: owner,
            target: {:repository, repository.id},
            metadata: %{"slug" => repository.slug, "name" => repository.name}
          )

          {:ok, repository}
        end
      end)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp check_repository_quota(user_id) do
    max = max_user_repositories()

    if max > 0 do
      live = Repo.aggregate(from(r in Repository, where: r.user_id == ^user_id), :count)
      if live + 1 > max, do: {:error, :quota_exceeded}, else: :ok
    else
      :ok
    end
  end

  # Conditional claim: insert a live reservation, or on conflict revive a row
  # only when it is retired and its retained user_id matches the creator. No
  # returned row means the slug is unavailable (DESIGN.md: Slug Reservations).
  defp claim_slug(changeset, repository_id, owner, now) do
    slug = Ecto.Changeset.get_field(changeset, :slug)
    name = Ecto.Changeset.get_field(changeset, :name)
    {:ok, owner_uuid} = Ecto.UUID.dump(owner.id)
    {:ok, repo_uuid} = Ecto.UUID.dump(repository_id)

    result =
      Repo.query!(
        """
        INSERT INTO slug_reservations
          (slug, repository_id, user_id, repository_name, retired_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, NULL, $5, $5)
        ON CONFLICT (slug) DO UPDATE
          SET repository_id = EXCLUDED.repository_id,
              user_id = EXCLUDED.user_id,
              repository_name = EXCLUDED.repository_name,
              retired_at = NULL,
              updated_at = EXCLUDED.updated_at
          WHERE slug_reservations.retired_at IS NOT NULL
            AND slug_reservations.user_id = EXCLUDED.user_id
        RETURNING slug
        """,
        [slug, repo_uuid, owner_uuid, name, now]
      )

    case result.num_rows do
      1 ->
        :ok

      0 ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:slug, "has already been taken")
         |> Map.put(:action, :insert)}
    end
  end

  defp generate_initial_metadata(owner, changeset) do
    generation =
      Repodata.generate([],
        revision: 0,
        timestamp: DateTime.to_unix(DateTime.utc_now())
      )

    case Ecto.Changeset.get_field(changeset, :gpg_key_fingerprint) do
      nil ->
        {:ok, generation, nil}

      _fingerprint ->
        case Signing.sign_repomd(owner, generation.repomd_xml) do
          {:ok, armored} -> {:ok, generation, armored}
          {:error, :unavailable} -> {:error, :signing_unavailable}
        end
    end
  end

  # A new empty repository created with sign_rpms starts enabled (DESIGN.md:
  # POST /api/v1/repos).
  defp initial_signing_state(changeset) do
    if Ecto.Changeset.get_field(changeset, :sign_rpms), do: "enabled", else: "disabled"
  end

  ## Updates

  @doc """
  Updates repository settings (DESIGN.md: PATCH matrix). Only the owner or an
  admin may update; the slug is immutable and `rpm_signing_state` is
  server-managed. Enabling RPM signing on a non-empty repository requires the
  signing-transition machinery from the signing phase.
  """
  def update_repository(%User{} = actor, %Repository{} = repository, attrs) do
    with :ok <- authorize_manage(actor, repository) do
      owner = Repo.get!(User, repository.user_id)
      changeset = Repository.update_changeset(repository, attrs, owner)

      cond do
        not changeset.valid? ->
          {:error, %{changeset | action: :update}}

        enabling_on_non_empty?(changeset, repository) ->
          # Requires an enable_rpm_signing transition with per-package re-sign
          # items; unreachable until package upload exists (signing phase).
          {:error, :signing_transitions_not_implemented}

        true ->
          Repo.transact(fn ->
            changeset =
              if Ecto.Changeset.get_change(changeset, :sign_rpms) == false do
                Ecto.Changeset.put_change(changeset, :rpm_signing_state, "disabled")
              else
                maybe_enable_empty_signing(changeset, repository)
              end

            repository = Repo.update!(changeset)

            Audit.record!("repository.update",
              actor: actor,
              target: {:repository, repository.id},
              metadata: %{"changed" => changeset.changes |> Map.keys() |> Enum.map(&to_string/1)}
            )

            {:ok, repository}
          end)
      end
    end
  end

  defp enabling_on_non_empty?(changeset, repository) do
    Ecto.Changeset.get_change(changeset, :sign_rpms) == true and
      repository.sign_rpms == false and repository.package_count > 0
  end

  defp maybe_enable_empty_signing(changeset, repository) do
    if Ecto.Changeset.get_change(changeset, :sign_rpms) == true and
         repository.package_count == 0 do
      Ecto.Changeset.put_change(changeset, :rpm_signing_state, "enabled")
    else
      changeset
    end
  end

  ## Deletion

  @doc """
  Hard-deletes a repository in one transaction (DESIGN.md: Package Upload &
  Processing — repository deletion): locks the owner, repository, and live
  slug reservation in the global order, retires the reservation with the final
  display name, and removes the repository and its metadata cache.
  """
  def delete_repository(%User{} = actor, %Repository{} = repository) do
    with :ok <- authorize_manage(actor, repository) do
      {:ok, result} =
        Repo.transact(fn ->
          lock_user_row!(repository.user_id)

          case Repo.one(from(r in Repository, where: r.id == ^repository.id, lock: "FOR UPDATE")) do
            nil ->
              {:ok, {:error, :not_found}}

            %Repository{} = current ->
              reservation =
                Repo.one!(
                  from(s in SlugReservation, where: s.slug == ^current.slug, lock: "FOR UPDATE")
                )

              now = DateTime.utc_now(:second)

              {1, _} =
                Repo.update_all(
                  from(s in SlugReservation, where: s.slug == ^reservation.slug),
                  set: [
                    repository_id: nil,
                    retired_at: now,
                    repository_name: current.name,
                    updated_at: now
                  ]
                )

              Repo.delete!(current)

              Audit.record!("repository.delete",
                actor: actor,
                target: {:repository, current.id},
                metadata: %{"slug" => current.slug, "name" => current.name}
              )

              {:ok, :ok}
          end
        end)

      result
    end
  end

  ## Slug reservation administration

  @doc """
  Releases one retired slug reservation for general reuse (admin only). Live
  reservations cannot be released. Audited as `admin.slug_release`.
  """
  def release_retired_slug(%User{} = actor, slug) when is_binary(slug) do
    if actor.is_admin do
      {:ok, result} =
        Repo.transact(fn ->
          case Repo.one(from(s in SlugReservation, where: s.slug == ^slug, lock: "FOR UPDATE")) do
            nil ->
              {:ok, {:error, :not_found}}

            %SlugReservation{retired_at: nil} ->
              {:ok, {:error, :live_reservation}}

            %SlugReservation{} = reservation ->
              Repo.delete!(reservation)

              Audit.record!("admin.slug_release",
                actor: actor,
                target: :slug,
                metadata: %{"slug" => slug}
              )

              {:ok, :ok}
          end
        end)

      result
    else
      {:error, :forbidden}
    end
  end

  ## Helpers

  defp authorize_manage(%User{} = actor, %Repository{} = repository) do
    if actor.is_admin or actor.id == repository.user_id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp max_user_repositories do
    Application.get_env(:dark_zenith, :max_user_repositories, 100)
  end

  defp lock_user_row!(user_id) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.id))
  end
end
