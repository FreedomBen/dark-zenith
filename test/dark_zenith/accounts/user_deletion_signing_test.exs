defmodule DarkZenith.Accounts.UserDeletionSigningTest do
  @moduledoc """
  Signing transitions at account deletion (DESIGN.md: User Lifecycle): any
  transition still preparing/activating/active/finalizing/failed is marked
  canceled, encrypted candidate fields are nulled, and linked reservations
  are released in the deletion transaction; the rows are retained for audit
  with `user_id` cleared through ON DELETE SET NULL.
  """

  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.UploadsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.User
  alias DarkZenith.SigningTransitions.{Item, Transition}
  alias DarkZenith.Storage.Reservation

  setup do
    %{admin: admin_fixture(), target: user_fixture()}
  end

  defp attach!(user, transition) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [gpg_key_transition_id: transition.id]
      )

    transition
  end

  test "deletion cancels an unresolved pre-swap replacement and nulls candidate fields", ctx do
    transition =
      attach!(
        ctx.target,
        Repo.insert!(%Transition{
          kind: "replace_gpg_key",
          user_id: ctx.target.id,
          status: "failed",
          resume_status: "preparing",
          last_error_code: "signing_unavailable",
          phase_attempts: 20,
          prepared_gpg_key_private: "prepared-private-envelope",
          prepared_gpg_key_public: "prepared-public",
          prepared_primary_fingerprint: String.duplicate("A", 40),
          prepared_signing_fingerprint: String.duplicate("B", 40),
          prepared_expires_at: DateTime.add(DateTime.utc_now(:second), 90, :day)
        })
      )

    assert {:ok, :ok} = Accounts.admin_delete_user(ctx.admin, ctx.target.id)
    refute Repo.get(User, ctx.target.id)

    canceled = Repo.get!(Transition, transition.id)
    assert canceled.status == "canceled"
    assert canceled.completed_at
    assert canceled.resume_status == nil
    assert canceled.phase_next_attempt_at == nil
    assert canceled.user_id == nil
    assert canceled.prepared_gpg_key_private == nil
    assert canceled.prepared_gpg_key_public == nil
    assert canceled.prepared_primary_fingerprint == nil
    assert canceled.prepared_signing_fingerprint == nil
    assert canceled.prepared_expires_at == nil
  end

  test "deletion cancels leftover nonterminal items and releases linked reservations", ctx do
    transition =
      Repo.insert!(%Transition{
        kind: "delete_signed_packages",
        user_id: ctx.target.id,
        status: "active"
      })

    attach!(ctx.target, transition)

    # A lost-state pending item: its repository snapshot UUID points at an
    # already-deleted repository, and its reservation (quota user: the
    # target) references another owner's live repository to satisfy the FK.
    other_repo = repository_fixture(user_fixture())
    reservation = reservation_row_fixture(ctx.target, other_repo, %{kind: "resign"})
    now = DateTime.utc_now(:second)

    item =
      Repo.insert!(%Item{
        transition_id: transition.id,
        repository_id: Ecto.UUID.generate(),
        package_id: Ecto.UUID.generate(),
        expected_storage_path: "repos/gone/packages/p/w/p.rpm",
        expected_storage_version_id: "4_zv",
        reservation_id: reservation.id,
        status: "pending",
        next_attempt_at: now
      })

    assert {:ok, :ok} = Accounts.admin_delete_user(ctx.admin, ctx.target.id)

    canceled_item = Repo.get!(Item, item.id)
    assert canceled_item.status == "canceled"
    assert canceled_item.completed_at
    assert canceled_item.reservation_id == nil
    refute Repo.get(Reservation, reservation.id)

    assert Repo.get!(Transition, transition.id).status == "canceled"
  end

  test "terminal transitions are retained untouched", ctx do
    completed_at = DateTime.add(DateTime.utc_now(:second), -1, :day)

    transition =
      Repo.insert!(%Transition{
        kind: "clear_metadata_signing",
        user_id: ctx.target.id,
        status: "completed",
        completed_at: completed_at
      })

    assert {:ok, :ok} = Accounts.admin_delete_user(ctx.admin, ctx.target.id)

    retained = Repo.get!(Transition, transition.id)
    assert retained.status == "completed"
    assert retained.completed_at == completed_at
    assert retained.user_id == nil
  end
end
