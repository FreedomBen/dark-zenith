defmodule DarkZenith.Accounts.ApiKeyTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.ApiKey
  alias DarkZenith.Crypto

  describe "create_api_key/2" do
    setup do
      %{user: user_fixture()}
    end

    test "returns the plaintext exactly once with prefix and hash stored", %{user: user} do
      assert {:ok, {plaintext, api_key}} =
               Accounts.create_api_key(user, %{name: "CI read-only", scopes: ["repo:read"]})

      assert String.starts_with?(plaintext, "dzak_")
      assert byte_size(plaintext) == byte_size("dzak_") + 43
      assert api_key.key_prefix == String.slice(plaintext, 0, 12)
      assert api_key.key_hash == Crypto.token_hash(plaintext)
      assert api_key.user_id == user.id
      assert api_key.expires_at == nil
    end

    test "trims the name and enforces its limits", %{user: user} do
      assert {:ok, {_plaintext, api_key}} =
               Accounts.create_api_key(user, %{name: "  spaced  ", scopes: ["repo:read"]})

      assert api_key.name == "spaced"

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.create_api_key(user, %{name: "   ", scopes: ["repo:read"]})

      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{
                 name: String.duplicate("a", 101),
                 scopes: ["repo:read"]
               })

      assert %{name: ["should be at most 100 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{name: "bad\nname", scopes: ["repo:read"]})

      assert %{name: ["cannot contain control characters"]} = errors_on(changeset)
    end

    test "canonicalizes scopes by collapsing duplicates and sorting", %{user: user} do
      assert {:ok, {_plaintext, api_key}} =
               Accounts.create_api_key(user, %{
                 name: "key",
                 scopes: ["repo:update", "repo:read", "repo:update", "package:upload"]
               })

      assert api_key.scopes == ["package:upload", "repo:read", "repo:update"]
    end

    test "requires at least one valid scope", %{user: user} do
      assert {:error, changeset} = Accounts.create_api_key(user, %{name: "key", scopes: []})
      assert %{scopes: ["should have at least 1 item(s)"]} = errors_on(changeset)

      assert {:error, changeset} = Accounts.create_api_key(user, %{name: "key"})
      assert %{scopes: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects unknown, empty, and non-string scope members", %{user: user} do
      assert {:error, changeset} =
               Accounts.create_api_key(user, %{name: "key", scopes: ["repo:admin"]})

      assert %{scopes: [message]} = errors_on(changeset)
      assert message =~ "invalid"

      assert {:error, changeset} = Accounts.create_api_key(user, %{name: "key", scopes: [""]})
      assert %{scopes: [_]} = errors_on(changeset)

      assert {:error, changeset} = Accounts.create_api_key(user, %{name: "key", scopes: [1]})
      assert %{scopes: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{name: "key", scopes: "repo:read"})

      assert %{scopes: [_]} = errors_on(changeset)
    end

    test "accepts every valid scope", %{user: user} do
      scopes = ~w(repo:read repo:create repo:update repo:delete package:upload package:delete)

      assert {:ok, {_plaintext, api_key}} =
               Accounts.create_api_key(user, %{name: "key", scopes: Enum.shuffle(scopes)})

      assert api_key.scopes == Enum.sort(scopes)
    end

    test "accepts a future expires_at and rejects past values", %{user: user} do
      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      assert {:ok, {_plaintext, api_key}} =
               Accounts.create_api_key(user, %{
                 name: "key",
                 scopes: ["repo:read"],
                 expires_at: future
               })

      assert api_key.expires_at == future

      past = DateTime.add(DateTime.utc_now(:second), -1, :second)

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{
                 name: "key",
                 scopes: ["repo:read"],
                 expires_at: past
               })

      assert %{expires_at: ["must be in the future"]} = errors_on(changeset)
    end
  end

  describe "fetch_api_key_user/1" do
    setup do
      user = user_fixture()

      {:ok, {plaintext, api_key}} =
        Accounts.create_api_key(user, %{name: "key", scopes: ["repo:read"]})

      %{user: user, plaintext: plaintext, api_key: api_key}
    end

    test "returns the user and key for a valid credential", %{
      user: user,
      plaintext: plaintext,
      api_key: api_key
    } do
      assert {:ok, {found_user, found_key}} = Accounts.fetch_api_key_user(plaintext)
      assert found_user.id == user.id
      assert found_key.id == api_key.id
    end

    test "rejects an unknown credential" do
      assert {:error, :invalid} = Accounts.fetch_api_key_user("dzak_unknown")
    end

    test "rejects an expired key as an invalid credential", %{
      plaintext: plaintext,
      api_key: api_key
    } do
      expire_api_key(api_key)

      assert {:error, :invalid} = Accounts.fetch_api_key_user(plaintext)
    end
  end

  describe "list_api_keys/1" do
    test "lists keys newest first, including expired rows" do
      user = user_fixture()
      other = user_fixture()

      {:ok, {_, first}} = Accounts.create_api_key(user, %{name: "first", scopes: ["repo:read"]})
      {:ok, {_, second}} = Accounts.create_api_key(user, %{name: "second", scopes: ["repo:read"]})
      {:ok, _} = Accounts.create_api_key(other, %{name: "other", scopes: ["repo:read"]})

      # Force distinct insertion timestamps for deterministic ordering.
      {1, _} =
        Repo.update_all(from(k in ApiKey, where: k.id == ^first.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :second)]
        )

      expire_api_key(second)

      assert [%{id: id2}, %{id: id1}] = Accounts.list_api_keys(user)
      assert id2 == second.id
      assert id1 == first.id
    end
  end

  describe "expired?/1" do
    test "is false for nil and future expirations, true for past" do
      refute ApiKey.expired?(%ApiKey{expires_at: nil})
      refute ApiKey.expired?(%ApiKey{expires_at: DateTime.add(DateTime.utc_now(), 60, :second)})
      assert ApiKey.expired?(%ApiKey{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
    end
  end

  describe "delete_api_key/2" do
    test "deletes the user's own key" do
      user = user_fixture()
      {:ok, {_, api_key}} = Accounts.create_api_key(user, %{name: "key", scopes: ["repo:read"]})

      assert :ok = Accounts.delete_api_key(user, api_key.id)
      assert Accounts.list_api_keys(user) == []
    end

    test "cannot delete another user's key" do
      user = user_fixture()
      other = user_fixture()
      {:ok, {_, api_key}} = Accounts.create_api_key(other, %{name: "key", scopes: ["repo:read"]})

      assert :error = Accounts.delete_api_key(user, api_key.id)
      assert [_] = Accounts.list_api_keys(other)
    end
  end

  describe "revoke_all_api_keys/1" do
    test "deletes only the user's keys" do
      user = user_fixture()
      other = user_fixture()
      {:ok, _} = Accounts.create_api_key(user, %{name: "a", scopes: ["repo:read"]})
      {:ok, _} = Accounts.create_api_key(user, %{name: "b", scopes: ["repo:read"]})
      {:ok, _} = Accounts.create_api_key(other, %{name: "c", scopes: ["repo:read"]})

      assert {2, _} = Accounts.revoke_all_api_keys(user)
      assert Accounts.list_api_keys(user) == []
      assert [_] = Accounts.list_api_keys(other)
    end
  end

  describe "API keys survive password changes" do
    test "password reset keeps API keys" do
      user = user_fixture()
      {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "key", scopes: ["repo:read"]})

      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})

      assert {:ok, _} = Accounts.fetch_api_key_user(plaintext)
    end
  end

  defp expire_api_key(api_key) do
    past = DateTime.add(DateTime.utc_now(:second), -61, :second)

    {1, _} =
      Repo.update_all(
        from(k in ApiKey, where: k.id == ^api_key.id),
        set: [expires_at: past]
      )
  end
end
