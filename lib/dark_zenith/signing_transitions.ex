defmodule DarkZenith.SigningTransitions do
  @moduledoc """
  Durable signing transitions (DESIGN.md: Signing Transitions; RPM signing).

  The repository-local `enable_rpm_signing` kind is fully implemented: one
  atomic transaction creates the active transition, one pending item per
  current package (snapshotting exact storage path/version), flips the
  repository to `sign_rpms = true` / `rpm_signing_state = "signing"`, and
  enqueues one job per item. Completion is evaluated solely from durable
  item state plus the metadata cache revision. User-wide kinds
  (replace/clear/delete) build on these tables in a later phase.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.Repo
  alias DarkZenith.Repositories.{MetadataCache, Repository}
  alias DarkZenith.SigningTransitions.{Item, Transition, TransitionRepository}
  alias DarkZenith.Storage
  alias DarkZenith.Workers.RetryPolicy

  @item_lease_seconds 900
  @max_item_attempts 20

  ## Reads

  def get_transition(id), do: Repo.get(Transition, id)

  def list_items(transition_id) do
    Repo.all(
      from i in Item, where: i.transition_id == ^transition_id, order_by: [asc: i.inserted_at]
    )
  end

  @doc "Item counts by status for progress display."
  def item_counts(transition_id) do
    counts =
      Repo.all(
        from i in Item,
          where: i.transition_id == ^transition_id,
          group_by: i.status,
          select: {i.status, count(i.id)}
      )
      |> Map.new()

    Map.merge(
      %{"pending" => 0, "executing" => 0, "succeeded" => 0, "failed" => 0, "canceled" => 0},
      counts
    )
  end

  @doc "Repository-snapshot counts by application status for progress display."
  def repository_counts(transition_id) do
    counts =
      Repo.all(
        from sr in TransitionRepository,
          where: sr.transition_id == ^transition_id,
          group_by: sr.application_status,
          select: {sr.application_status, count(sr.id)}
      )
      |> Map.new()

    Map.merge(%{"pending" => 0, "applied" => 0, "satisfied_deleted" => 0}, counts)
  end

  ## The owner-level write fence (DESIGN.md: Signing Transition Repositories)

  @doc """
  The user-wide transition fence for an owner, or nil. `scope: :all` blocks
  creations and deletions (replacement preparing/activating; removal
  preparing); `scope: :creations` blocks repository/package creation and
  signing-setting changes but admits explicit deletions (removal after
  preparation). Replacement `active` blocks nothing.
  """
  def user_fence(user_id) do
    transition =
      Repo.one(
        from t in Transition,
          join: u in User,
          on: u.gpg_key_transition_id == t.id,
          where: u.id == ^user_id
      )

    transition && fence_for(transition)
  end

  defp fence_for(transition) do
    phase =
      if transition.status == "failed", do: transition.resume_status, else: transition.status

    scope =
      case {transition.kind, phase} do
        {"replace_gpg_key", p} when p in ["preparing", "activating"] -> :all
        {"replace_gpg_key", _} -> nil
        {_removal, "preparing"} -> :all
        {_removal, p} when p in ["activating", "active", "finalizing"] -> :creations
        _ -> nil
      end

    scope && %{transition: transition, scope: scope}
  end

  @doc """
  Guards an owner mutation against the fence. `op` is `:create` (repository
  or package creation, signing-setting changes) or `:delete` (explicit
  repository/package deletion).
  """
  def check_owner_mutation(user_id, op) when op in [:create, :delete] do
    case user_fence(user_id) do
      nil -> :ok
      %{scope: :all} -> {:error, :gpg_key_transition_in_progress}
      %{scope: :creations} when op == :create -> {:error, :gpg_key_transition_in_progress}
      %{scope: :creations} -> :ok
    end
  end

  @doc """
  Marks pending snapshot rows for a deleted repository satisfied inside the
  deletion transaction; deletion can only reduce the affected state.
  """
  def satisfy_repository_rows_for_deleted_repository!(repository_id) do
    now = DateTime.utc_now(:second)

    {_count, _} =
      Repo.update_all(
        from(sr in TransitionRepository,
          join: t in Transition,
          on: t.id == sr.transition_id,
          where:
            sr.repository_id == ^repository_id and sr.application_status == "pending" and
              t.status in ["preparing", "activating", "active", "finalizing", "failed"]
        ),
        set: [application_status: "satisfied_deleted", applied_at: now]
      )

    :ok
  end

  ## Enable RPM signing (repository-local)

  @doc """
  Enables RPM signing on a non-empty repository with the explicit re-sign
  strategy, inside the caller's transaction holding the owner and
  repository locks. Writes at most `MAX_REPOSITORY_PACKAGES` items — the
  reason that variable carries a hard upper bound.
  """
  def enable_rpm_signing!(%Repository{} = repository, %User{} = owner) do
    now = DateTime.utc_now(:second)

    transition =
      Repo.insert!(%Transition{
        kind: "enable_rpm_signing",
        user_id: owner.id,
        repository_id: repository.id,
        target_fingerprint: owner.gpg_signing_fingerprint,
        status: "active"
      })

    packages =
      Repo.all(
        from p in DarkZenith.Packages.Package,
          where: p.repository_id == ^repository.id,
          order_by: [asc: p.id],
          lock: "FOR UPDATE",
          select: %{
            id: p.id,
            storage_path: p.storage_path,
            storage_version_id: p.storage_version_id
          }
      )

    items =
      for package <- packages do
        %{
          id: Ecto.UUID.generate(),
          transition_id: transition.id,
          repository_id: repository.id,
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

    Repo.insert_all(Item, items)

    for item <- items do
      %{item_id: item.id}
      |> DarkZenith.Workers.SigningItem.new()
      |> Oban.insert!()
    end

    transition
  end

  @doc """
  Cancels a repository-local transition and its unfinished items inside the
  caller's transaction (disable, package deletion joins via
  `cancel_items_for_package!`, repository deletion via
  `cancel_transitions_for_repository!`).
  """
  def cancel_transition!(%Transition{} = transition) do
    now = DateTime.utc_now(:second)

    release_and_cancel_items(from(i in Item, where: i.transition_id == ^transition.id), now)

    {1, _} =
      Repo.update_all(
        from(t in Transition,
          where:
            t.id == ^transition.id and
              t.status in ["preparing", "activating", "active", "finalizing", "failed"]
        ),
        set: [
          status: "canceled",
          resume_status: nil,
          phase_next_attempt_at: nil,
          prepared_gpg_key_private: nil,
          prepared_gpg_key_public: nil,
          prepared_primary_fingerprint: nil,
          prepared_signing_fingerprint: nil,
          prepared_expires_at: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    :ok
  end

  @doc "Cancels every unfinished item for a package (its deletion transaction)."
  def cancel_items_for_package!(package_id) do
    now = DateTime.utc_now(:second)
    release_and_cancel_items(from(i in Item, where: i.package_id == ^package_id), now)
    :ok
  end

  @doc """
  Cancels active/failed transitions for a deleted repository, including
  every unfinished item referencing it (its deletion transaction).
  """
  def cancel_transitions_for_repository!(repository_id) do
    now = DateTime.utc_now(:second)

    release_and_cancel_items(from(i in Item, where: i.repository_id == ^repository_id), now)

    {_count, _} =
      Repo.update_all(
        from(t in Transition,
          where:
            t.repository_id == ^repository_id and
              t.status in ["preparing", "activating", "active", "finalizing", "failed"]
        ),
        set: [
          status: "canceled",
          resume_status: nil,
          phase_next_attempt_at: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    :ok
  end

  defp release_and_cancel_items(scope, now) do
    unfinished = from i in scope, where: i.status in ["pending", "executing", "failed"]

    reservation_ids =
      Repo.all(
        from i in unfinished, where: not is_nil(i.reservation_id), select: i.reservation_id
      )

    {_count, _} =
      Repo.update_all(unfinished,
        set: [
          status: "canceled",
          reservation_id: nil,
          next_attempt_at: nil,
          lease_token: nil,
          lease_expires_at: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    Enum.each(reservation_ids, &Storage.release_reservation/1)
  end

  ## Item lifecycle (used by the item worker)

  @doc """
  Claims one due pending item whose parent is `active` (or failed resuming
  active). Returns `{:ok, item, transition, token}` or `:skip`.
  """
  def claim_item(item_id) do
    now = DateTime.utc_now(:second)
    token = Ecto.UUID.generate()

    {:ok, result} =
      Repo.transact(fn ->
        item = Repo.one(from i in Item, where: i.id == ^item_id, lock: "FOR UPDATE")

        transition =
          item &&
            Repo.one(from t in Transition, where: t.id == ^item.transition_id, lock: "FOR UPDATE")

        claimable? =
          item && item.status == "pending" &&
            DateTime.compare(item.next_attempt_at, now) != :gt &&
            transition_admits_items?(transition)

        if claimable? do
          {1, _} =
            Repo.update_all(
              from(i in Item, where: i.id == ^item.id),
              set: [
                status: "executing",
                lease_token: token,
                lease_expires_at: DateTime.add(now, @item_lease_seconds, :second),
                next_attempt_at: nil,
                updated_at: now
              ],
              inc: [attempts: 1]
            )

          if item.reservation_id, do: Storage.renew_reservation(item.reservation_id)
          {:ok, {:ok, Repo.get!(Item, item.id), transition, token}}
        else
          {:ok, :skip}
        end
      end)

    result
  end

  defp transition_admits_items?(nil), do: false

  defp transition_admits_items?(transition) do
    transition.status == "active" or
      (transition.status == "failed" and transition.resume_status == "active")
  end

  @doc """
  Extends an executing item's lease under its fencing token; `:halt` means
  the claim was canceled or superseded.
  """
  def renew_item_lease(item_id, token) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(i in Item,
          where: i.id == ^item_id and i.status == "executing" and i.lease_token == ^token
        ),
        set: [lease_expires_at: DateTime.add(now, @item_lease_seconds, :second), updated_at: now]
      )

    if count == 1, do: :ok, else: :halt
  end

  @doc "Marks a claimed item canceled (its package/repository is gone)."
  def cancel_claimed_item(item, token) do
    now = DateTime.utc_now(:second)

    {_count, _} =
      Repo.update_all(
        from(i in Item,
          where: i.id == ^item.id and i.status == "executing" and i.lease_token == ^token
        ),
        set: [
          status: "canceled",
          reservation_id: nil,
          lease_token: nil,
          lease_expires_at: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    if item.reservation_id, do: Storage.release_reservation(item.reservation_id)
    :ok
  end

  @doc """
  Deterministic item failure: the item and its transition fail immediately
  with the stable code and `resume_status = "active"`.
  """
  def item_deterministic_failure(item, token, code) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.transact(fn ->
        {count, _} =
          Repo.update_all(
            from(i in Item,
              where: i.id == ^item.id and i.status == "executing" and i.lease_token == ^token
            ),
            set: [
              status: "failed",
              reservation_id: nil,
              lease_token: nil,
              lease_expires_at: nil,
              last_error_code: code,
              completed_at: now,
              updated_at: now
            ]
          )

        if count == 1 do
          if item.reservation_id, do: Storage.release_reservation(item.reservation_id)
          fail_transition!(item.transition_id, code)
        end

        {:ok, :ok}
      end)

    :ok
  end

  @doc """
  Transient item failure under Background Retry Policy; the twentieth
  failed claim is terminal and fails the transition.
  """
  def item_transient_failure(item, token, code) do
    now = DateTime.utc_now(:second)

    if item.attempts >= @max_item_attempts do
      item_deterministic_failure(item, token, code)
    else
      next_at = DateTime.add(now, RetryPolicy.backoff(item.attempts), :second)

      {:ok, _} =
        Repo.transact(fn ->
          {count, _} =
            Repo.update_all(
              from(i in Item,
                where: i.id == ^item.id and i.status == "executing" and i.lease_token == ^token
              ),
              set: [
                status: "pending",
                lease_token: nil,
                lease_expires_at: nil,
                next_attempt_at: next_at,
                last_error_code: code,
                updated_at: now
              ]
            )

          {:ok, count}
        end)

      %{item_id: item.id}
      |> DarkZenith.Workers.SigningItem.new(scheduled_at: next_at)
      |> Oban.insert!()

      :ok
    end
  end

  @doc """
  Owner-fence deferral for a claimed repository-local item: released back to
  pending one minute ahead with its pre-claim attempt value restored, so the
  pause consumes none of the budget.
  """
  def defer_item(item, token) do
    now = DateTime.utc_now(:second)
    next_at = DateTime.add(now, 60, :second)

    {count, _} =
      Repo.update_all(
        from(i in Item,
          where: i.id == ^item.id and i.status == "executing" and i.lease_token == ^token
        ),
        set: [
          status: "pending",
          lease_token: nil,
          lease_expires_at: nil,
          next_attempt_at: next_at,
          updated_at: now
        ],
        inc: [attempts: -1]
      )

    if count == 1 do
      %{item_id: item.id}
      |> DarkZenith.Workers.SigningItem.new(scheduled_at: next_at)
      |> Oban.insert!()
    end

    :ok
  end

  def fail_transition!(transition_id, code) do
    now = DateTime.utc_now(:second)

    {_count, _} =
      Repo.update_all(
        from(t in Transition, where: t.id == ^transition_id and t.status == "active"),
        set: [
          status: "failed",
          resume_status: "active",
          last_error_code: code,
          updated_at: now
        ]
      )

    :ok
  end

  ## Completion and the 60-second sweep

  @doc """
  Completes an enable transition when every item is succeeded or canceled
  and the metadata cache has reached the current revision: the repository
  becomes `enabled`, the transition ID clears, and the transition
  completes.
  """
  def check_completion(transition_id) do
    case Repo.one(from t in Transition, where: t.id == ^transition_id, select: t.kind) do
      "replace_gpg_key" ->
        DarkZenith.SigningTransitions.UserWide.check_replace_completion(transition_id)

      "delete_signed_packages" ->
        DarkZenith.SigningTransitions.UserWide.check_delete_completion(transition_id)

      "enable_rpm_signing" ->
        check_enable_completion(transition_id)

      _clear_or_missing ->
        :not_yet
    end
  end

  defp check_enable_completion(transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        transition =
          Repo.one(
            from t in Transition,
              where: t.id == ^transition_id and t.status == "active",
              lock: "FOR UPDATE"
          )

        with %Transition{kind: "enable_rpm_signing"} <- transition,
             false <- unfinished_items?(transition.id),
             %Repository{} = repository <-
               Repo.one(
                 from r in Repository,
                   where: r.id == ^transition.repository_id,
                   lock: "FOR UPDATE"
               ),
             true <- cache_current?(repository) do
          {1, _} =
            Repo.update_all(
              from(r in Repository, where: r.id == ^repository.id),
              set: [
                rpm_signing_state: "enabled",
                signing_transition_id: nil,
                updated_at: now
              ]
            )

          {1, _} =
            Repo.update_all(
              from(t in Transition, where: t.id == ^transition.id),
              set: [status: "completed", completed_at: now, updated_at: now]
            )

          {:ok, :completed}
        else
          _ -> {:ok, :not_yet}
        end
      end)

    result
  end

  defp unfinished_items?(transition_id) do
    Repo.exists?(
      from i in Item,
        where:
          i.transition_id == ^transition_id and
            i.status in ["pending", "executing", "failed"]
    )
  end

  defp cache_current?(repository) do
    revision =
      Repo.one(
        from c in MetadataCache,
          where: c.repository_id == ^repository.id,
          select: c.source_revision
      )

    revision == repository.metadata_revision
  end

  @doc """
  The 60-second sweep: requeues expired item execution leases and evaluates
  completion for active enable transitions.
  """
  def sweep do
    now = DateTime.utc_now(:second)

    expired_ids =
      Repo.all(
        from i in Item,
          where: i.status == "executing" and i.lease_expires_at <= ^now,
          select: i.id
      )

    Enum.each(expired_ids, fn id ->
      {:ok, _} =
        Repo.transact(fn ->
          item = Repo.one(from i in Item, where: i.id == ^id, lock: "FOR UPDATE")

          if item && item.status == "executing" &&
               DateTime.compare(item.lease_expires_at, now) != :gt do
            next_at = DateTime.add(now, RetryPolicy.backoff(max(item.attempts, 1)), :second)

            {1, _} =
              Repo.update_all(
                from(i in Item, where: i.id == ^id),
                set: [
                  status: "pending",
                  lease_token: nil,
                  lease_expires_at: nil,
                  next_attempt_at: next_at,
                  updated_at: now
                ]
              )

            %{item_id: id}
            |> DarkZenith.Workers.SigningItem.new(scheduled_at: next_at)
            |> Oban.insert!()
          end

          {:ok, :ok}
        end)
    end)

    active_ids =
      Repo.all(
        from t in Transition,
          where: t.kind == "enable_rpm_signing" and t.status == "active",
          select: t.id
      )

    Enum.each(active_ids, &check_completion/1)
    DarkZenith.SigningTransitions.UserWide.sweep()
    :ok
  end

  ## Admin intervention

  @doc """
  Resets selected failed items to pending with a fresh attempt budget,
  recording prior attempt counts in the audit event, returning the failed
  transition to active when no failed items remain, and enqueuing jobs.
  """
  def admin_reset_items(%User{is_admin: true} = actor, transition_id, item_ids) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        items =
          Repo.all(
            from i in Item,
              where:
                i.transition_id == ^transition_id and i.id in ^item_ids and
                  i.status == "failed",
              lock: "FOR UPDATE"
          )

        prior = Map.new(items, &{&1.id, &1.attempts})

        {_count, _} =
          Repo.update_all(
            from(i in Item, where: i.id in ^Enum.map(items, & &1.id)),
            set: [
              status: "pending",
              attempts: 0,
              next_attempt_at: now,
              lease_token: nil,
              lease_expires_at: nil,
              last_error_code: nil,
              completed_at: nil,
              updated_at: now
            ]
          )

        still_failed? =
          Repo.exists?(
            from i in Item, where: i.transition_id == ^transition_id and i.status == "failed"
          )

        unless still_failed? do
          Repo.update_all(
            from(t in Transition,
              where:
                t.id == ^transition_id and t.status == "failed" and t.resume_status == "active"
            ),
            set: [status: "active", resume_status: nil, last_error_code: nil, updated_at: now]
          )
        end

        Audit.record!("signing_transition.item_reset",
          actor: actor,
          target: {:signing_transition, transition_id},
          metadata: %{"prior_attempts" => prior}
        )

        for item <- items do
          %{item_id: item.id}
          |> DarkZenith.Workers.SigningItem.new()
          |> Oban.insert!()
        end

        {:ok, length(items)}
      end)

    {:ok, result}
  end

  def admin_reset_items(%User{}, _transition_id, _item_ids), do: {:error, :forbidden}

  @doc "Transitions for the admin view, unresolved first, newest first."
  def admin_list_transitions do
    Repo.all(
      from t in Transition,
        order_by: [
          asc: t.status in ["completed", "canceled"],
          desc: t.inserted_at,
          asc: t.id
        ]
    )
  end

  @doc """
  Restores a failed transition to its recorded `resume_status` with a fresh
  attempt budget and schedules the next phase batch and affected
  regeneration jobs (DESIGN.md: Admin — Signing transitions).
  """
  def admin_reset_phase(%User{is_admin: true} = actor, transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        transition =
          Repo.one(from t in Transition, where: t.id == ^transition_id, lock: "FOR UPDATE")

        cond do
          is_nil(transition) ->
            {:ok, {:error, :not_found}}

          transition.status != "failed" ->
            {:ok, {:error, :not_failed}}

          true ->
            resume = transition.resume_status
            batch_phase? = resume in ["preparing", "activating", "finalizing"]

            {1, _} =
              Repo.update_all(
                from(t in Transition, where: t.id == ^transition_id),
                set: [
                  status: resume,
                  resume_status: nil,
                  last_error_code: nil,
                  phase_attempts: 0,
                  phase_next_attempt_at: if(batch_phase?, do: now),
                  updated_at: now
                ]
              )

            Audit.record!("signing_transition.phase_reset",
              actor: actor,
              target: {:signing_transition, transition_id},
              metadata: %{
                "resume_status" => resume,
                "prior_attempts" => transition.phase_attempts
              }
            )

            {:ok, {:ok, transition, resume, batch_phase?}}
        end
      end)

    with {:ok, transition, resume, batch_phase?} <- result do
      if batch_phase? do
        %{transition_id: transition_id}
        |> DarkZenith.Workers.SigningPhase.new()
        |> Oban.insert!()
      else
        # An active resume: item work continues; give affected
        # regeneration a fresh budget too.
        DarkZenith.SigningTransitions.UserWide.enqueue_item_jobs(transition_id)
        enqueue_stale_snapshot_regeneration(transition_id)

        if transition.kind == "enable_rpm_signing" && resume == "active" &&
             transition.repository_id do
          DarkZenith.Repodata.enqueue_regeneration(transition.repository_id)
        end

        check_completion(transition_id)
      end

      :ok
    end
  end

  def admin_reset_phase(%User{}, _transition_id), do: {:error, :forbidden}

  defp enqueue_stale_snapshot_regeneration(transition_id) do
    repository_ids =
      Repo.all(
        from sr in TransitionRepository,
          join: r in Repository,
          on: r.id == sr.repository_id,
          left_join: c in MetadataCache,
          on: c.repository_id == r.id,
          where:
            sr.transition_id == ^transition_id and sr.application_status == "applied" and
              (is_nil(c.source_revision) or c.source_revision != r.metadata_revision),
          select: r.id
      )

    Enum.each(repository_ids, &DarkZenith.Repodata.enqueue_regeneration/1)
  end

  @doc """
  Cancels a transition where the flow permits it: a repository-local enable
  (disabling signing on the repository), a pre-swap replacement, or a
  removal that has not started applying. A post-swap replacement offers
  only reset/resume.
  """
  def admin_cancel_transition(%User{is_admin: true} = actor, transition_id) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        # Global lock order: owner row before the transition row.
        user_id =
          Repo.one(from t in Transition, where: t.id == ^transition_id, select: t.user_id)

        if user_id do
          Repo.one(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
        end

        transition =
          Repo.one(from t in Transition, where: t.id == ^transition_id, lock: "FOR UPDATE")

        case cancelability(transition) do
          {:error, reason} ->
            {:ok, {:error, reason}}

          {:ok, mode} ->
            apply_admin_cancel!(transition, mode, now)

            Audit.record!("signing_transition.cancel",
              actor: actor,
              target: {:signing_transition, transition_id},
              metadata: %{"kind" => transition.kind, "status" => transition.status}
            )

            {:ok, :ok}
        end
      end)

    result
  end

  def admin_cancel_transition(%User{}, _transition_id), do: {:error, :forbidden}

  defp cancelability(nil), do: {:error, :not_found}

  defp cancelability(%Transition{status: status}) when status in ["completed", "canceled"],
    do: {:error, :not_cancelable}

  defp cancelability(%Transition{kind: "enable_rpm_signing"}), do: {:ok, :enable}

  defp cancelability(%Transition{kind: "replace_gpg_key"} = transition) do
    phase =
      if transition.status == "failed", do: transition.resume_status, else: transition.status

    # Once the key swap has committed, ending the replacement would strand
    # previous_gpg_key_public and split repositories across two keys.
    if phase == "preparing", do: {:ok, :user_wide}, else: {:error, :not_cancelable}
  end

  defp cancelability(%Transition{} = transition) do
    phase =
      if transition.status == "failed", do: transition.resume_status, else: transition.status

    if phase == "preparing", do: {:ok, :user_wide}, else: {:error, :not_cancelable}
  end

  defp apply_admin_cancel!(transition, :enable, now) do
    cancel_transition!(transition)

    if transition.repository_id do
      {_count, _} =
        Repo.update_all(
          from(r in Repository,
            where: r.id == ^transition.repository_id and r.signing_transition_id == ^transition.id
          ),
          set: [
            sign_rpms: false,
            rpm_signing_state: "disabled",
            signing_transition_id: nil,
            updated_at: now
          ]
        )
    end
  end

  defp apply_admin_cancel!(transition, :user_wide, now) do
    cancel_transition!(transition)

    {_count, _} =
      Repo.update_all(
        from(u in User,
          where: u.id == ^transition.user_id and u.gpg_key_transition_id == ^transition.id
        ),
        set: [gpg_key_transition_id: nil, updated_at: now]
      )
  end
end
