defmodule DarkZenith.SigningTransitions.UserWide do
  @moduledoc """
  User-wide GPG key transitions (DESIGN.md: Key replacement and revocation;
  Signing Transitions): durable `replace_gpg_key`, `clear_metadata_signing`,
  and `delete_signed_packages` flows.

  Large transitions are never constructed or applied in one transaction:
  phase workers process UUID-ordered batches of
  `SIGNING_PREPARATION_BATCH_SIZE`, use unique upserts, and advance
  cursors/apply rows while resetting `phase_attempts` in the same
  transaction. Transient batch failures follow Background Retry Policy; the
  twentieth changes the transition to `failed` with `resume_status`
  recording the phase.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Accounts.UserNotifier
  alias DarkZenith.Audit
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.SigningTransitions
  alias DarkZenith.SigningTransitions.{Item, Transition, TransitionRepository}
  alias DarkZenith.Workers.RetryPolicy

  @max_phase_attempts 20
  @expiry_floor_days 30
  @unresolved ["preparing", "activating", "active", "finalizing", "failed"]

  ## Creation

  @doc """
  Starts a durable key replacement after full candidate validation. The
  candidate is held only in the transition's encrypted prepared fields; the
  current key and every repository fingerprint remain unchanged until the
  key-swap commit.
  """
  def start_replacement(%User{} = user, public_armored, private_armored) do
    with {:ok, info} <- DarkZenith.Gpg.validate_key_pair(public_armored, private_armored) do
      envelope = DarkZenith.Crypto.GpgKeyEnvelope.encrypt(private_armored, user.id)

      {:ok, result} =
        Repo.transact(fn ->
          lock_user!(user.id)
          current = Repo.get!(User, user.id)
          now = DateTime.utc_now(:second)

          cond do
            is_nil(current.gpg_key_fingerprint) ->
              {:ok, {:error, :no_current_key}}

            current.gpg_key_transition_id ->
              {:ok, {:error, :transition_in_progress}}

            signing_repository_exists?(user.id) ->
              {:ok, {:error, :transition_in_progress}}

            true ->
              transition =
                Repo.insert!(%Transition{
                  kind: "replace_gpg_key",
                  user_id: user.id,
                  target_fingerprint: info.signing_fingerprint,
                  prepared_gpg_key_private: envelope,
                  prepared_gpg_key_public: public_armored,
                  prepared_primary_fingerprint: info.primary_fingerprint,
                  prepared_signing_fingerprint: info.signing_fingerprint,
                  prepared_expires_at:
                    info.expires_at && DateTime.truncate(info.expires_at, :second),
                  status: "preparing",
                  phase_next_attempt_at: now
                })

              attach_and_start!(current, transition, now)

              Audit.record!("gpg_key.replace_start",
                actor: user,
                target: {:signing_transition, transition.id},
                metadata: %{"target_fingerprint" => info.primary_fingerprint}
              )

              {:ok, {:accepted, transition}}
          end
        end)

      result
    end
  end

  @doc """
  Starts a durable removal transition (`clear_metadata_signing` or
  `delete_signed_packages`). A non-replacement strategy atomically cancels
  an unresolved replacement; an unresolved removal transition is refused.
  """
  def start_removal(%User{} = user, kind)
      when kind in ["clear_metadata_signing", "delete_signed_packages"] do
    {:ok, result} =
      Repo.transact(fn ->
        lock_user!(user.id)
        current = Repo.get!(User, user.id)
        now = DateTime.utc_now(:second)

        existing =
          current.gpg_key_transition_id &&
            Repo.one(
              from t in Transition,
                where: t.id == ^current.gpg_key_transition_id,
                lock: "FOR UPDATE"
            )

        cond do
          is_nil(current.gpg_key_fingerprint) ->
            {:ok, {:error, :not_found}}

          existing && existing.kind != "replace_gpg_key" ->
            {:ok, {:error, :transition_in_progress}}

          kind == "clear_metadata_signing" and rpm_signing_repository_exists?(user.id) ->
            {:ok, {:error, :in_use}}

          true ->
            # A removal supersedes an unresolved replacement: the old
            # transition cancels (nulling its candidate and items) and the
            # removal snapshots the still-current repository/package state.
            if existing, do: SigningTransitions.cancel_transition!(existing)

            transition =
              Repo.insert!(%Transition{
                kind: kind,
                user_id: user.id,
                status: "preparing",
                phase_next_attempt_at: now
              })

            attach_and_start!(current, transition, now)

            Audit.record!("gpg_key.revocation_start",
              actor: user,
              target: {:signing_transition, transition.id},
              metadata: %{"strategy" => kind}
            )

            {:ok, {:accepted, transition}}
        end
      end)

    result
  end

  defp attach_and_start!(user, transition, now) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [gpg_key_transition_id: transition.id, updated_at: now]
      )

    enqueue_phase_job(transition.id)
  end

  @doc "Counts for the `conflict_gpg_key_in_use` details payload."
  def affected_repository_counts(user_id) do
    %{
      metadata_signed:
        Repo.aggregate(
          from(r in Repository,
            where: r.user_id == ^user_id and not is_nil(r.gpg_key_fingerprint)
          ),
          :count
        ),
      rpm_signed:
        Repo.aggregate(
          from(r in Repository, where: r.user_id == ^user_id and r.sign_rpms),
          :count
        )
    }
  end

  ## Phase execution (the SigningPhase worker entry point)

  @doc """
  Runs one bounded phase batch for a user-wide transition. Each invocation
  performs one batch and re-enqueues itself while work remains.
  """
  def run_phase(transition_id) do
    transition = Repo.get(Transition, transition_id)

    case transition && {transition.kind, transition.status} do
      nil ->
        :ok

      {kind, "preparing"} when kind != "enable_rpm_signing" ->
        guarded_batch(transition, "preparing", &prepare_batch/1)

      {"replace_gpg_key", "activating"} ->
        guarded_batch(transition, "activating", &activate_batch/1)

      {kind, "finalizing"} when kind in ["clear_metadata_signing", "delete_signed_packages"] ->
        guarded_batch(transition, "finalizing", &finalize_batch/1)

      {_kind, "active"} ->
        SigningTransitions.check_completion(transition_id)
        :ok

      _terminal_or_failed ->
        :ok
    end
  end

  # Transient batch errors follow Background Retry Policy on the durable
  # phase counters; the twentieth failure records the phase for admin reset.
  defp guarded_batch(transition, phase, batch_fun) do
    batch_fun.(transition)
  rescue
    error ->
      code =
        case error do
          %DBConnection.ConnectionError{} -> "database_unavailable"
          _ -> "signing_transition_phase_error"
        end

      record_phase_failure(transition.id, phase, code)
      :ok
  end

  @doc false
  def __record_phase_failure_for_tests__(transition_id, phase, code) do
    record_phase_failure(transition_id, phase, code)
  end

  defp record_phase_failure(transition_id, phase, code) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.transact(fn ->
        transition =
          Repo.one(from t in Transition, where: t.id == ^transition_id, lock: "FOR UPDATE")

        cond do
          is_nil(transition) or transition.status != phase ->
            {:ok, :stale}

          transition.phase_attempts + 1 >= @max_phase_attempts ->
            {1, _} =
              Repo.update_all(
                from(t in Transition, where: t.id == ^transition_id),
                set: [
                  status: "failed",
                  resume_status: phase,
                  last_error_code: code,
                  phase_next_attempt_at: nil,
                  updated_at: now
                ],
                inc: [phase_attempts: 1]
              )

            {:ok, :failed}

          true ->
            next_at =
              DateTime.add(now, RetryPolicy.backoff(transition.phase_attempts + 1), :second)

            {1, _} =
              Repo.update_all(
                from(t in Transition, where: t.id == ^transition_id),
                set: [
                  phase_next_attempt_at: next_at,
                  last_error_code: code,
                  updated_at: now
                ],
                inc: [phase_attempts: 1]
              )

            enqueue_phase_job(transition_id, next_at)
            {:ok, :scheduled}
        end
      end)

    :ok
  end

  ## Preparation

  defp prepare_batch(transition) do
    now = DateTime.utc_now(:second)

    {:ok, outcome} =
      Repo.transact(fn ->
        current = lock_transition!(transition.id)

        cond do
          is_nil(current) or current.status != "preparing" ->
            {:ok, :stale}

          not due?(current.phase_next_attempt_at, now) ->
            {:ok, :stale}

          not current.repositories_preparation_complete ->
            prepare_repositories_batch(current, now)

          not current.packages_preparation_complete ->
            prepare_packages_batch(current, now)

          true ->
            {:ok, :prepared}
        end
      end)

    case outcome do
      :more -> enqueue_phase_job(transition.id)
      :prepared -> leave_preparation(transition.id)
      :stale -> :ok
    end

    :ok
  end

  defp prepare_repositories_batch(transition, now) do
    cursor = transition.repositories_prepared_through

    rows =
      Repo.all(
        repository_scope(transition)
        |> after_cursor(cursor)
        |> order_by([r], asc: r.id)
        |> limit(^batch_size())
        |> select([r], r.id)
      )

    if rows == [] do
      update_transition!(transition.id,
        set: [
          repositories_preparation_complete: true,
          phase_attempts: 0,
          phase_next_attempt_at: now,
          updated_at: now
        ]
      )

      {:ok, :more}
    else
      snapshot_rows =
        for repository_id <- rows do
          %{
            id: Ecto.UUID.generate(),
            transition_id: transition.id,
            repository_id: repository_id,
            application_status: "pending",
            inserted_at: now
          }
        end

      Repo.insert_all(TransitionRepository, snapshot_rows,
        on_conflict: :nothing,
        conflict_target: [:transition_id, :repository_id]
      )

      update_transition!(transition.id,
        set: [
          repositories_prepared_through: List.last(rows),
          phase_attempts: 0,
          phase_next_attempt_at: now,
          updated_at: now
        ]
      )

      {:ok, :more}
    end
  end

  defp prepare_packages_batch(transition, now) do
    if transition.kind == "clear_metadata_signing" do
      # Empty by definition: no owned repository has sign_rpms.
      update_transition!(transition.id,
        set: [
          packages_preparation_complete: true,
          phase_attempts: 0,
          phase_next_attempt_at: now,
          updated_at: now
        ]
      )

      {:ok, :more}
    else
      packages = package_batch(transition, transition.packages_prepared_through)

      if packages == [] do
        update_transition!(transition.id,
          set: [
            packages_preparation_complete: true,
            phase_attempts: 0,
            phase_next_attempt_at: now,
            updated_at: now
          ]
        )

        {:ok, :more}
      else
        items =
          for package <- packages do
            %{
              id: Ecto.UUID.generate(),
              transition_id: transition.id,
              repository_id: package.repository_id,
              package_id: package.id,
              expected_storage_path: package.storage_path,
              expected_storage_version_id: package.storage_version_id,
              status: "pending",
              attempts: 0,
              next_attempt_at: now,
              inserted_at: now,
              updated_at: now
            }
          end

        Repo.insert_all(Item, items,
          on_conflict: :nothing,
          conflict_target: [:transition_id, :package_id]
        )

        update_transition!(transition.id,
          set: [
            packages_prepared_through: List.last(packages).id,
            phase_attempts: 0,
            phase_next_attempt_at: now,
            updated_at: now
          ]
        )

        {:ok, :more}
      end
    end
  end

  defp package_batch(transition, cursor) do
    base =
      from p in Package,
        join: r in Repository,
        on: r.id == p.repository_id,
        where: r.user_id == ^transition.user_id and r.sign_rpms,
        order_by: [asc: p.id],
        limit: ^batch_size(),
        select: %{
          id: p.id,
          repository_id: p.repository_id,
          storage_path: p.storage_path,
          storage_version_id: p.storage_version_id
        }

    query = if cursor, do: from(p in base, where: p.id > ^cursor), else: base
    Repo.all(query)
  end

  # Both scans complete: replacement swaps keys, clearing finalizes, and
  # deletion begins its item work.
  defp leave_preparation(transition_id) do
    transition = Repo.get!(Transition, transition_id)

    case transition.kind do
      "replace_gpg_key" -> key_swap(transition_id)
      "clear_metadata_signing" -> enter_finalizing(transition_id)
      "delete_signed_packages" -> enter_delete_active(transition_id)
    end
  end

  ## The key-swap commit (replacement)

  defp key_swap(transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, outcome} =
      Repo.transact(fn ->
        user_id =
          Repo.one(from t in Transition, where: t.id == ^transition_id, select: t.user_id)

        user = user_id && lock_user!(user_id)
        transition = lock_transition!(transition_id)

        cond do
          is_nil(transition) or transition.status != "preparing" or is_nil(user) ->
            {:ok, :stale}

          not (transition.repositories_preparation_complete and
                   transition.packages_preparation_complete) ->
            {:ok, :stale}

          below_expiry_floor?(transition.prepared_expires_at, now) ->
            # The candidate no longer meets the 30-day floor: cancel safely,
            # current key untouched.
            cancel_locked!(transition, user, now)
            {:ok, :canceled}

          true ->
            {1, _} =
              Repo.update_all(
                from(u in User, where: u.id == ^user.id),
                set: [
                  previous_gpg_key_public: user.gpg_key_public,
                  gpg_key_private: transition.prepared_gpg_key_private,
                  gpg_key_public: transition.prepared_gpg_key_public,
                  gpg_key_fingerprint: transition.prepared_primary_fingerprint,
                  gpg_signing_fingerprint: transition.prepared_signing_fingerprint,
                  gpg_key_expires_at: transition.prepared_expires_at,
                  gpg_key_expiry_notified_days: [],
                  updated_at: now
                ]
              )

            update_transition!(transition.id,
              set: [
                status: "activating",
                prepared_gpg_key_private: nil,
                prepared_gpg_key_public: nil,
                prepared_primary_fingerprint: nil,
                prepared_signing_fingerprint: nil,
                prepared_expires_at: nil,
                repositories_prepared_through: nil,
                packages_prepared_through: nil,
                phase_attempts: 0,
                phase_next_attempt_at: now,
                updated_at: now
              ]
            )

            Audit.record!("gpg_key.replace_swap",
              actor: user,
              target: {:signing_transition, transition.id},
              metadata: %{"fingerprint" => transition.prepared_primary_fingerprint}
            )

            UserNotifier.deliver_gpg_key_replaced(user, transition.prepared_primary_fingerprint)
            {:ok, :swapped}
        end
      end)

    if outcome == :swapped, do: enqueue_phase_job(transition_id)
    :ok
  end

  defp below_expiry_floor?(nil, _now), do: false

  defp below_expiry_floor?(expires_at, now) do
    DateTime.compare(expires_at, DateTime.add(now, @expiry_floor_days * 86_400, :second)) == :lt
  end

  ## Activation (replacement repository application)

  defp activate_batch(transition) do
    now = DateTime.utc_now(:second)

    {:ok, outcome} =
      Repo.transact(fn ->
        owner = lock_user!(transition.user_id)
        current = lock_transition!(transition.id)

        cond do
          is_nil(current) or current.status != "activating" ->
            {:ok, :stale}

          not due?(current.phase_next_attempt_at, now) ->
            {:ok, :stale}

          true ->
            rows = claim_pending_repository_rows(current.id)

            if rows == [] do
              enter_replace_active(current, owner, now)
              {:ok, :active}
            else
              Enum.each(rows, fn row ->
                apply_replacement_row!(row, owner, now)
              end)

              update_transition!(current.id,
                set: [phase_attempts: 0, phase_next_attempt_at: now, updated_at: now]
              )

              {:ok, :more}
            end
        end
      end)

    case outcome do
      :more -> enqueue_phase_job(transition.id)
      :active -> SigningTransitions.check_completion(transition.id)
      :stale -> :ok
    end

    :ok
  end

  defp apply_replacement_row!(row, owner, now) do
    repository =
      Repo.one(from r in Repository, where: r.id == ^row.repository_id, lock: "FOR UPDATE")

    if repository do
      {1, _} =
        Repo.update_all(
          from(r in Repository, where: r.id == ^repository.id),
          set: [gpg_key_fingerprint: owner.gpg_key_fingerprint, updated_at: now],
          inc: [metadata_revision: 1]
        )

      mark_row!(row.id, "applied", now)
      Repodata.enqueue_regeneration(repository.id)
    else
      mark_row!(row.id, "satisfied_deleted", now)
    end
  end

  # Activation finished: item work begins and new uploads are admitted.
  defp enter_replace_active(transition, owner, now) do
    update_transition!(transition.id,
      set: [phase_attempts: 0, phase_next_attempt_at: nil, status: "active", updated_at: now]
    )

    enqueue_item_jobs(transition.id)
    schedule_deferred_owner_uploads(owner.id, now)
  end

  ## Delete-kind phase changes

  defp enter_delete_active(transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.transact(fn ->
        current = lock_transition!(transition_id)

        if current && current.status == "preparing" do
          update_transition!(transition_id,
            set: [
              status: "active",
              repositories_prepared_through: nil,
              packages_prepared_through: nil,
              phase_attempts: 0,
              phase_next_attempt_at: nil,
              updated_at: now
            ]
          )

          enqueue_item_jobs(transition_id)
        end

        {:ok, :ok}
      end)

    SigningTransitions.check_completion(transition_id)
    :ok
  end

  defp enter_finalizing(transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.transact(fn ->
        current = lock_transition!(transition_id)

        if current && current.status in ["preparing", "active"] do
          update_transition!(transition_id,
            set: [
              status: "finalizing",
              repositories_prepared_through: nil,
              packages_prepared_through: nil,
              phase_attempts: 0,
              phase_next_attempt_at: now,
              updated_at: now
            ]
          )

          enqueue_phase_job(transition_id)
        end

        {:ok, :ok}
      end)

    :ok
  end

  ## Finalization (both removal kinds)

  defp finalize_batch(transition) do
    now = DateTime.utc_now(:second)

    {:ok, outcome} =
      Repo.transact(fn ->
        owner = lock_user!(transition.user_id)
        current = lock_transition!(transition.id)

        cond do
          is_nil(current) or current.status != "finalizing" ->
            {:ok, :stale}

          not due?(current.phase_next_attempt_at, now) ->
            {:ok, :stale}

          true ->
            rows = claim_pending_repository_rows(current.id)

            if rows == [] do
              complete_removal!(current, owner, now)
              {:ok, :completed}
            else
              Enum.each(rows, fn row ->
                apply_removal_row!(current, row, now)
              end)

              update_transition!(current.id,
                set: [phase_attempts: 0, phase_next_attempt_at: now, updated_at: now]
              )

              {:ok, :more}
            end
        end
      end)

    if outcome == :more, do: enqueue_phase_job(transition.id)
    :ok
  end

  defp apply_removal_row!(transition, row, now) do
    repository =
      Repo.one(from r in Repository, where: r.id == ^row.repository_id, lock: "FOR UPDATE")

    if repository do
      # Cancel the repository's own enable transition (if any) before
      # disabling signing so unfinished child jobs no-op.
      if transition.kind == "delete_signed_packages" and repository.signing_transition_id do
        case Repo.get(Transition, repository.signing_transition_id) do
          nil -> :ok
          child -> SigningTransitions.cancel_transition!(child)
        end
      end

      settings =
        case transition.kind do
          "clear_metadata_signing" ->
            [gpg_key_fingerprint: nil, updated_at: now]

          "delete_signed_packages" ->
            [
              gpg_key_fingerprint: nil,
              sign_rpms: false,
              rpm_signing_state: "disabled",
              signing_transition_id: nil,
              updated_at: now
            ]
        end

      {1, _} =
        Repo.update_all(
          from(r in Repository, where: r.id == ^repository.id),
          set: settings,
          inc: [metadata_revision: 1]
        )

      mark_row!(row.id, "applied", now)
      Repodata.enqueue_regeneration(repository.id)
    else
      mark_row!(row.id, "satisfied_deleted", now)
    end
  end

  # The final commit removes key material and completes the transition.
  defp complete_removal!(transition, owner, now) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^owner.id),
        set: [
          gpg_key_private: nil,
          gpg_key_public: nil,
          gpg_key_fingerprint: nil,
          gpg_signing_fingerprint: nil,
          gpg_key_expires_at: nil,
          gpg_key_expiry_notified_days: [],
          previous_gpg_key_public: nil,
          gpg_key_transition_id: nil,
          updated_at: now
        ]
      )

    update_transition!(transition.id,
      set: [
        status: "completed",
        phase_attempts: 0,
        phase_next_attempt_at: nil,
        completed_at: now,
        updated_at: now
      ]
    )

    Audit.record!("gpg_key.remove",
      actor: owner,
      target: {:signing_transition, transition.id},
      metadata: %{"strategy" => transition.kind}
    )

    UserNotifier.deliver_gpg_key_removed(owner)
    schedule_deferred_owner_uploads(owner.id, now)
  end

  ## Completion checks (called from SigningTransitions.check_completion)

  @doc false
  def check_replace_completion(transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        user_id =
          Repo.one(from t in Transition, where: t.id == ^transition_id, select: t.user_id)

        user = user_id && lock_user!(user_id)
        transition = lock_transition!(transition_id)

        with %Transition{kind: "replace_gpg_key", status: "active"} <- transition,
             false <- unfinished_items?(transition.id),
             false <- pending_repository_rows?(transition.id),
             false <- stale_applied_caches?(transition.id) do
          if user do
            {1, _} =
              Repo.update_all(
                from(u in User, where: u.id == ^user.id),
                set: [
                  previous_gpg_key_public: nil,
                  gpg_key_transition_id: nil,
                  updated_at: now
                ]
              )
          end

          update_transition!(transition.id,
            set: [
              status: "completed",
              phase_attempts: 0,
              phase_next_attempt_at: nil,
              completed_at: now,
              updated_at: now
            ]
          )

          if user do
            Audit.record!("gpg_key.replace_complete",
              actor: user,
              target: {:signing_transition, transition.id},
              metadata: %{"fingerprint" => user.gpg_key_fingerprint}
            )
          end

          {:ok, :completed}
        else
          _ -> {:ok, :not_yet}
        end
      end)

    result
  end

  @doc false
  def check_delete_completion(transition_id) do
    {:ok, result} =
      Repo.transact(fn ->
        transition = lock_transition!(transition_id)

        with %Transition{kind: "delete_signed_packages", status: "active"} <- transition,
             false <- unfinished_items?(transition.id) do
          {:ok, :items_done}
        else
          _ -> {:ok, :not_yet}
        end
      end)

    if result == :items_done, do: enter_finalizing(transition_id)
    result
  end

  ## Cancellation

  @doc """
  Cancels an unresolved replacement inside the caller's transaction (the
  immediate-delete path and admin pre-swap cancel): nulls the candidate,
  cancels items, releases the user pointer.
  """
  def cancel_replacement_locked!(%Transition{} = transition, %User{} = user) do
    cancel_locked!(transition, user, DateTime.utc_now(:second))
  end

  defp cancel_locked!(transition, user, now) do
    SigningTransitions.cancel_transition!(transition)

    {_count, _} =
      Repo.update_all(
        from(u in User,
          where: u.id == ^user.id and u.gpg_key_transition_id == ^transition.id
        ),
        set: [gpg_key_transition_id: nil, updated_at: now]
      )

    :ok
  end

  ## Regeneration exhaustion (DESIGN.md: Key replacement step 7)

  @doc """
  Marks the owner's unresolved user-wide transition failed when metadata
  regeneration for one of their repositories exhausts its attempts, so a
  permanently stale cache is visible outside Oban retention.
  """
  def record_regeneration_exhaustion(repository_id) do
    now = DateTime.utc_now(:second)

    owner_id =
      Repo.one(from r in Repository, where: r.id == ^repository_id, select: r.user_id)

    if owner_id do
      {:ok, _} =
        Repo.transact(fn ->
          transition =
            Repo.one(
              from t in Transition,
                join: u in User,
                on: u.gpg_key_transition_id == t.id,
                where: u.id == ^owner_id and t.status in ["activating", "active", "finalizing"],
                lock: "FOR UPDATE"
            )

          if transition do
            {1, _} =
              Repo.update_all(
                from(t in Transition, where: t.id == ^transition.id),
                set: [
                  status: "failed",
                  resume_status: transition.status,
                  last_error_code: "metadata_generation_failed",
                  phase_next_attempt_at: nil,
                  updated_at: now
                ]
              )
          end

          {:ok, :ok}
        end)
    end

    :ok
  end

  ## The 60-second sweep contribution

  @doc """
  Schedules due phase work and missing item jobs for unresolved user-wide
  transitions, and evaluates completion for active ones.
  """
  def sweep do
    now = DateTime.utc_now(:second)

    due_phase_ids =
      Repo.all(
        from t in Transition,
          where:
            t.kind != "enable_rpm_signing" and
              t.status in ["preparing", "activating", "finalizing"] and
              t.phase_next_attempt_at <= ^now,
          select: t.id
      )

    Enum.each(due_phase_ids, &enqueue_phase_job/1)

    active_ids =
      Repo.all(
        from t in Transition,
          where: t.kind != "enable_rpm_signing" and t.status == "active",
          select: t.id
      )

    Enum.each(active_ids, fn id ->
      enqueue_item_jobs(id)
      SigningTransitions.check_completion(id)
    end)

    :ok
  end

  @doc "Enqueues one bounded batch of jobs for due pending items."
  def enqueue_item_jobs(transition_id) do
    now = DateTime.utc_now(:second)

    item_ids =
      Repo.all(
        from i in Item,
          where:
            i.transition_id == ^transition_id and i.status == "pending" and
              i.next_attempt_at <= ^now,
          order_by: [asc: i.id],
          limit: ^batch_size(),
          select: i.id
      )

    for item_id <- item_ids do
      %{item_id: item_id}
      |> DarkZenith.Workers.SigningItem.new()
      |> Oban.insert!()
    end

    :ok
  end

  ## Shared helpers

  defp enqueue_phase_job(transition_id, scheduled_at \\ nil) do
    args = %{transition_id: transition_id}

    job =
      if scheduled_at do
        DarkZenith.Workers.SigningPhase.new(args, scheduled_at: scheduled_at)
      else
        DarkZenith.Workers.SigningPhase.new(args)
      end

    Oban.insert!(job)
    :ok
  end

  # Uploads deferred by the fence are scheduled immediately at the phase
  # change that admits them, avoiding a full-minute tail.
  defp schedule_deferred_owner_uploads(owner_id, now) do
    intent_ids =
      Repo.all(
        from i in DarkZenith.Uploads.Intent,
          join: r in Repository,
          on: r.id == i.repository_id,
          where: r.user_id == ^owner_id and i.status == "queued" and i.next_attempt_at > ^now,
          select: i.id
      )

    {_count, _} =
      Repo.update_all(
        from(i in DarkZenith.Uploads.Intent, where: i.id in ^intent_ids),
        set: [next_attempt_at: now, updated_at: now]
      )

    Enum.each(intent_ids, &DarkZenith.Uploads.enqueue_processing(&1, now))
    :ok
  end

  defp claim_pending_repository_rows(transition_id) do
    Repo.all(
      from sr in TransitionRepository,
        where: sr.transition_id == ^transition_id and sr.application_status == "pending",
        order_by: [asc: sr.id],
        limit: ^batch_size(),
        lock: "FOR UPDATE"
    )
  end

  defp mark_row!(row_id, status, now) do
    {1, _} =
      Repo.update_all(
        from(sr in TransitionRepository, where: sr.id == ^row_id),
        set: [application_status: status, applied_at: now]
      )
  end

  defp repository_scope(%Transition{kind: "delete_signed_packages", user_id: user_id}) do
    from r in Repository,
      where: r.user_id == ^user_id and (not is_nil(r.gpg_key_fingerprint) or r.sign_rpms)
  end

  defp repository_scope(%Transition{user_id: user_id}) do
    from r in Repository,
      where: r.user_id == ^user_id and not is_nil(r.gpg_key_fingerprint)
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: from(r in query, where: r.id > ^cursor)

  defp unfinished_items?(transition_id) do
    Repo.exists?(
      from i in Item,
        where:
          i.transition_id == ^transition_id and
            i.status in ["pending", "executing", "failed"]
    )
  end

  defp pending_repository_rows?(transition_id) do
    Repo.exists?(
      from sr in TransitionRepository,
        where: sr.transition_id == ^transition_id and sr.application_status == "pending"
    )
  end

  # Every surviving applied-snapshot repository must have a current cache.
  defp stale_applied_caches?(transition_id) do
    Repo.exists?(
      from sr in TransitionRepository,
        join: r in Repository,
        on: r.id == sr.repository_id,
        left_join: c in DarkZenith.Repositories.MetadataCache,
        on: c.repository_id == r.id,
        where:
          sr.transition_id == ^transition_id and sr.application_status == "applied" and
            (is_nil(c.source_revision) or c.source_revision != r.metadata_revision)
    )
  end

  defp signing_repository_exists?(user_id) do
    Repo.exists?(
      from r in Repository, where: r.user_id == ^user_id and r.rpm_signing_state == "signing"
    )
  end

  defp rpm_signing_repository_exists?(user_id) do
    Repo.exists?(from r in Repository, where: r.user_id == ^user_id and r.sign_rpms)
  end

  defp lock_transition!(id) do
    Repo.one(from t in Transition, where: t.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_user!(id) do
    Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
  end

  defp update_transition!(id, updates) do
    {1, _} = Repo.update_all(from(t in Transition, where: t.id == ^id), updates)
  end

  defp due?(nil, _now), do: false
  defp due?(at, now), do: DateTime.compare(at, now) != :gt

  defp batch_size do
    Application.get_env(:dark_zenith, :signing_preparation_batch_size, 1000)
  end

  @doc "Unresolved statuses for user-wide transitions."
  def unresolved_statuses, do: @unresolved
end
