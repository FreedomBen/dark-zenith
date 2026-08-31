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
    base = from r in Repository, as: :repository, order_by: [asc: r.slug, asc: r.id]

    case user do
      nil ->
        from r in base, where: r.is_public

      %User{is_admin: true} ->
        base

      %User{id: user_id} ->
        collaborated =
          from c in DarkZenith.Collaborators.Collaborator,
            where: c.repository_id == parent_as(:repository).id and c.user_id == ^user_id

        from r in base,
          where: r.is_public or r.user_id == ^user_id or exists(collaborated)
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

        with :ok <- DarkZenith.SigningTransitions.check_owner_mutation(owner.id, :create),
             :ok <- check_repository_quota(owner.id),
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
          {:error, :expired} -> {:error, :gpg_key_expired}
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

      signing_change? =
        Map.has_key?(changeset.changes, :gpg_key_fingerprint) or
          Map.has_key?(changeset.changes, :sign_rpms)

      cond do
        not changeset.valid? ->
          {:error, %{changeset | action: :update}}

        signing_change? and
            DarkZenith.SigningTransitions.check_owner_mutation(owner.id, :create) != :ok ->
          {:error, :gpg_key_transition_in_progress}

        enabling_on_non_empty?(changeset, repository) ->
          enable_rpm_signing_with_transition(actor, repository, changeset, owner)

        true ->
          Repo.transact(fn ->
            disabling? = Ecto.Changeset.get_change(changeset, :sign_rpms) == false

            changeset =
              if disabling? do
                changeset
                |> Ecto.Changeset.put_change(:rpm_signing_state, "disabled")
                |> Ecto.Changeset.put_change(:signing_transition_id, nil)
              else
                maybe_enable_empty_signing(changeset, repository)
              end

            # Disabling cancels the running enable transition and every
            # unfinished item; already-written signatures are kept.
            if disabling? && repository.signing_transition_id do
              case DarkZenith.SigningTransitions.get_transition(repository.signing_transition_id) do
                nil -> :ok
                transition -> DarkZenith.SigningTransitions.cancel_transition!(transition)
              end
            end

            changed_settings = changeset.changes |> Map.keys() |> Enum.map(&to_string/1)

            # A metadata-signing change (gpg_key_fingerprint) affects
            # generated metadata: bump the revision and enqueue regeneration
            # (DESIGN.md: Metadata Generation & Storage).
            metadata_changed? = Map.has_key?(changeset.changes, :gpg_key_fingerprint)

            changeset =
              if metadata_changed? do
                Ecto.Changeset.put_change(
                  changeset,
                  :metadata_revision,
                  repository.metadata_revision + 1
                )
              else
                changeset
              end

            repository = Repo.update!(changeset)

            if metadata_changed?, do: Repodata.enqueue_regeneration(repository.id)

            Audit.record!("repository.update",
              actor: actor,
              target: {:repository, repository.id},
              metadata: %{"changed" => changed_settings}
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

  # Enabling on a non-empty repository: one atomic transaction creates the
  # active enable_rpm_signing transition, one pending item per current
  # package, flips the repository to signing, and enqueues the item jobs
  # (DESIGN.md: RPM signing).
  defp enable_rpm_signing_with_transition(actor, repository, changeset, owner) do
    Repo.transact(fn ->
      lock_user_row!(repository.user_id)

      current =
        Repo.one!(from r in Repository, where: r.id == ^repository.id, lock: "FOR UPDATE")

      cond do
        current.signing_transition_id ->
          {:error, :conflict_gpg_key_transition_in_progress}

        is_nil(owner.gpg_signing_fingerprint) ->
          {:error,
           changeset
           |> Ecto.Changeset.add_error(:sign_rpms, "requires a configured GPG key")
           |> Map.put(:action, :update)}

        true ->
          transition = DarkZenith.SigningTransitions.enable_rpm_signing!(current, owner)

          updated =
            changeset
            |> Ecto.Changeset.put_change(:rpm_signing_state, "signing")
            |> Ecto.Changeset.put_change(:signing_transition_id, transition.id)
            |> Repo.update!()

          Audit.record!("repository.update",
            actor: actor,
            target: {:repository, updated.id},
            metadata: %{"changed" => ["sign_rpms"], "transition_id" => transition.id}
          )

          {:ok, updated}
      end
    end)
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
  Processing — repository deletion): records every package and staged
  version, locks the owner, repository, package rows, upload intents,
  reservations, and live slug reservation in the global order, removes the
  repository and its dependents (fencing workers through the deleted
  durable state), decrements the owner's `storage_bytes`, retires the slug
  with the final display name, and enqueues idempotent version-aware B2
  cleanup for every final and staging object.
  """
  def delete_repository(%User{} = actor, %Repository{} = repository) do
    with :ok <- authorize_manage(actor, repository) do
      {:ok, result} =
        Repo.transact(fn ->
          lock_user_row!(repository.user_id)

          case DarkZenith.SigningTransitions.check_owner_mutation(repository.user_id, :delete) do
            {:error, reason} ->
              {:ok, {:error, reason}}

            :ok ->
              delete_repository_locked(actor, repository)
          end
        end)

      result
    end
  end

  defp delete_repository_locked(actor, repository) do
          case Repo.one(from(r in Repository, where: r.id == ^repository.id, lock: "FOR UPDATE")) do
            nil ->
              {:ok, {:error, :not_found}}

            %Repository{} = current ->
              packages =
                Repo.all(
                  from p in DarkZenith.Packages.Package,
                    where: p.repository_id == ^current.id,
                    order_by: [asc: p.id],
                    lock: "FOR UPDATE",
                    select: %{
                      storage_path: p.storage_path,
                      storage_version_id: p.storage_version_id,
                      size_package: p.size_package
                    }
                )

              intents =
                Repo.all(
                  from i in DarkZenith.Uploads.Intent,
                    where: i.repository_id == ^current.id,
                    order_by: [asc: i.id],
                    lock: "FOR UPDATE",
                    select: %{staging_path: i.staging_path}
                )

              Repo.all(
                from r in DarkZenith.Storage.Reservation,
                  where: r.repository_id == ^current.id,
                  order_by: [asc: r.id],
                  lock: "FOR UPDATE",
                  select: r.id
              )

              reservation =
                Repo.one!(
                  from(s in SlugReservation, where: s.slug == ^current.slug, lock: "FOR UPDATE")
                )

              DarkZenith.SigningTransitions.cancel_transitions_for_repository!(current.id)
              DarkZenith.SigningTransitions.satisfy_repository_rows_for_deleted_repository!(current.id)

              stored_bytes = packages |> Enum.map(& &1.size_package) |> Enum.sum()

              if stored_bytes > 0 do
                {1, _} =
                  Repo.update_all(
                    from(u in User, where: u.id == ^current.user_id),
                    inc: [storage_bytes: -stored_bytes]
                  )
              end

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

              # Dependent packages, collaborators, invitations, the metadata
              # cache, upload intents, and reservations delete through their
              # foreign keys; workers are fenced by the removed durable rows.
              Repo.delete!(current)

              Audit.record!("repository.delete",
                actor: actor,
                target: {:repository, current.id},
                metadata: %{"slug" => current.slug, "name" => current.name}
              )

              for package <- packages do
                %{
                  storage_path: package.storage_path,
                  version_id: package.storage_version_id
                }
                |> DarkZenith.Workers.FinalVersionCleanup.new()
                |> Oban.insert!()
              end

              for intent <- intents do
                %{staging_path: intent.staging_path}
                |> DarkZenith.Workers.StagingCleanup.new()
                |> Oban.insert!()
              end

              {:ok, :ok}
          end
  end

  @doc "All slug reservations for the admin view, retired first, newest first."
  def list_slug_reservations do
    Repo.all(
      from s in SlugReservation,
        order_by: [asc: is_nil(s.retired_at), desc: s.updated_at, asc: s.slug]
    )
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
