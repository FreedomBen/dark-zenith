defmodule DarkZenith.ReleaseTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.Release

  describe "promote_admin/1" do
    test "promotes a confirmed user when no admin exists" do
      user = user_fixture()

      assert {:ok, promoted} = Release.promote_admin(user.email)
      assert promoted.is_admin
      assert Repo.get!(User, user.id).is_admin

      assert [event] = Audit.list_events(limit: 1)
      assert event.action == "admin.recovery_promote"
      assert event.actor_id == nil
      assert event.target_type == "user"
      assert event.target_id == user.id
    end

    test "normalizes and validates the email" do
      user = user_fixture()

      assert {:ok, _} = Release.promote_admin("  " <> String.upcase(user.email) <> "  ")
      assert {:error, :invalid_email} = Release.promote_admin("not an email")
    end

    test "refuses to act when an admin already exists" do
      admin_fixture()
      user = user_fixture()

      assert {:error, :admin_exists} = Release.promote_admin(user.email)
      refute Repo.get!(User, user.id).is_admin
    end

    test "is safe to retry after success" do
      user = user_fixture()

      assert {:ok, _} = Release.promote_admin(user.email)
      assert {:error, :admin_exists} = Release.promote_admin(user.email)
    end

    test "refuses a missing user" do
      assert {:error, :user_not_found} = Release.promote_admin("missing@example.com")
    end

    test "refuses an unconfirmed user" do
      user = unconfirmed_user_fixture()

      assert {:error, :user_unconfirmed} = Release.promote_admin(user.email)
      refute Repo.get!(User, user.id).is_admin
    end

    test "never creates an account" do
      assert {:error, :user_not_found} = Release.promote_admin("missing@example.com")
      assert Repo.aggregate(User, :count) == 0
    end
  end
end
