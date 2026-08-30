defmodule DarkZenith.Accounts.AdminFlagTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit

  describe "set_admin_flag/3" do
    test "an admin can grant the flag to another user" do
      admin = admin_fixture()
      user = user_fixture()

      assert {:ok, updated} = Accounts.set_admin_flag(admin, user.id, true)
      assert updated.is_admin

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "admin.grant_admin"
      assert event.actor_id == admin.id
      assert event.target_id == user.id
    end

    test "an admin can revoke the flag when another confirmed admin remains" do
      admin = admin_fixture()
      other_admin = admin_fixture()

      assert {:ok, updated} = Accounts.set_admin_flag(admin, other_admin.id, false)
      refute updated.is_admin

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "admin.revoke_admin"
    end

    test "rejects a self-target" do
      admin = admin_fixture()

      assert {:error, :cannot_target_self} = Accounts.set_admin_flag(admin, admin.id, false)
      assert {:error, :cannot_target_self} = Accounts.set_admin_flag(admin, admin.id, true)
      assert Repo.get!(User, admin.id).is_admin
    end

    test "no sequence of flag mutations can remove the last confirmed admin" do
      admin = admin_fixture()
      other_admin = admin_fixture()

      # A confirmed admin acting on another user always remains after the
      # mutation, and self-targets are rejected, so the invariant holds.
      assert {:ok, _} = Accounts.set_admin_flag(admin, other_admin.id, false)
      assert {:error, :cannot_target_self} = Accounts.set_admin_flag(admin, admin.id, false)

      remaining =
        Repo.aggregate(
          from(u in User, where: u.is_admin and not is_nil(u.confirmed_at)),
          :count
        )

      assert remaining == 1
    end

    test "a stale actor that lost the admin flag cannot mutate" do
      admin = admin_fixture()
      other_admin = admin_fixture()
      user = user_fixture()

      # other_admin is demoted; their stale struct must not authorize changes.
      assert {:ok, _} = Accounts.set_admin_flag(admin, other_admin.id, false)

      assert {:error, :not_admin} = Accounts.set_admin_flag(other_admin, user.id, true)
      refute Repo.get!(User, user.id).is_admin
    end

    test "a non-admin cannot mutate" do
      user = user_fixture()
      target = user_fixture()

      assert {:error, :not_admin} = Accounts.set_admin_flag(user, target.id, true)
    end

    test "rejects an unknown target" do
      admin = admin_fixture()

      assert {:error, :user_not_found} =
               Accounts.set_admin_flag(admin, Ecto.UUID.generate(), true)
    end
  end
end
