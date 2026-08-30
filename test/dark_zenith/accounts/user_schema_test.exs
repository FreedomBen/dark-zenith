defmodule DarkZenith.Accounts.UserSchemaTest do
  use DarkZenith.DataCase, async: true

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo

  import DarkZenith.AccountsFixtures

  test "new users default to non-admin with zero storage and no reminders sent" do
    user = user_fixture()

    assert user.is_admin == false
    assert user.storage_bytes == 0
    assert user.gpg_key_expiry_notified_days == []
    assert user.gpg_key_fingerprint == nil
  end

  test "storage_bytes cannot go negative" do
    user = user_fixture()

    assert_raise Postgrex.Error, ~r/users_storage_bytes_non_negative/, fn ->
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [storage_bytes: -1]
      )
    end
  end

  test "GPG key fields must be written together" do
    user = user_fixture()

    # A fingerprint without the rest of the key material violates the
    # all-or-none rule (DESIGN.md: Users).
    assert_raise Postgrex.Error, ~r/users_gpg_key_fields_together/, fn ->
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [gpg_key_fingerprint: String.duplicate("A", 40)]
      )
    end
  end

  test "a complete GPG key field set with reminder thresholds round-trips" do
    user = user_fixture()

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [
          gpg_key_private: <<2, 1, 2, 3>>,
          gpg_key_public: "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...",
          gpg_key_fingerprint: String.duplicate("A", 40),
          gpg_signing_fingerprint: String.duplicate("B", 40),
          gpg_key_expires_at: ~U[2030-01-01 00:00:00Z],
          gpg_key_expiry_notified_days: [30, 7]
        ]
      )

    reloaded = Repo.get!(User, user.id)
    assert reloaded.gpg_key_expiry_notified_days == [30, 7]
    assert reloaded.gpg_key_fingerprint == String.duplicate("A", 40)
    assert reloaded.gpg_key_expires_at == ~U[2030-01-01 00:00:00Z]
  end
end
