defmodule DarkZenith.Accounts.BootstrapTest do
  use DarkZenith.DataCase, async: true

  import ExUnit.CaptureLog
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.Bootstrap

  describe "bootstrap_admin/2" do
    test "creates a confirmed admin when no users exist" do
      assert {:ok, admin} = Bootstrap.bootstrap_admin("admin@example.com", "admin password 123")

      assert admin.is_admin
      assert admin.confirmed_at
      assert admin.email == "admin@example.com"
      assert {:ok, _} = Accounts.authenticate_user("admin@example.com", "admin password 123")
    end

    test "normalizes the email like registration does" do
      assert {:ok, admin} = Bootstrap.bootstrap_admin("Admin@Example.COM", "admin password 123")
      assert admin.email == "admin@example.com"
    end

    test "refuses to run when any user already exists" do
      user_fixture()

      assert {:error, :users_exist} =
               Bootstrap.bootstrap_admin("admin@example.com", "admin password 123")
    end

    test "applies the same validation rules as regular accounts" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Bootstrap.bootstrap_admin("not-an-email", "admin password 123")

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Bootstrap.bootstrap_admin("admin@example.com", "short")

      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
    end
  end

  describe "maybe_bootstrap_admin/1" do
    test "creates the admin from configuration" do
      assert {:ok, admin} =
               Bootstrap.maybe_bootstrap_admin(
                 email: "admin@example.com",
                 password: "admin password 123"
               )

      assert admin.is_admin
    end

    test "skips with a warning when credentials are absent" do
      log =
        capture_log(fn ->
          assert :skipped = Bootstrap.maybe_bootstrap_admin(email: nil, password: nil)
        end)

      assert log =~ "no admin user was created"
      assert Repo.aggregate(Accounts.User, :count) == 0
    end

    test "skips with a warning when only one credential is set" do
      log =
        capture_log(fn ->
          assert :skipped =
                   Bootstrap.maybe_bootstrap_admin(email: "admin@example.com", password: nil)
        end)

      assert log =~ "no admin user was created"
    end

    test "skips with a warning when credentials fail validation" do
      log =
        capture_log(fn ->
          assert :skipped =
                   Bootstrap.maybe_bootstrap_admin(email: "admin@example.com", password: "short")
        end)

      assert log =~ "no admin user was created"
      assert Repo.aggregate(Accounts.User, :count) == 0
    end

    test "is silently ignored once users exist" do
      user_fixture()

      assert :ignored =
               Bootstrap.maybe_bootstrap_admin(
                 email: "admin@example.com",
                 password: "admin password 123"
               )

      assert Repo.aggregate(Accounts.User, :count) == 1
    end
  end
end
