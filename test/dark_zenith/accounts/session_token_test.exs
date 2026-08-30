defmodule DarkZenith.Accounts.SessionTokenTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.SessionToken
  alias DarkZenith.Crypto

  describe "create_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "returns a dzst_-prefixed plaintext shown only once", %{user: user} do
      {plaintext, token} = Accounts.create_session_token(user)

      assert String.starts_with?(plaintext, "dzst_")
      # 32 random bytes as unpadded base64url = 43 characters.
      assert byte_size(plaintext) == byte_size("dzst_") + 43
      assert token.user_id == user.id
    end

    test "stores only the HMAC-SHA-256 hash of the full token string", %{user: user} do
      {plaintext, token} = Accounts.create_session_token(user)

      assert token.token_hash == Crypto.token_hash(plaintext)
      assert token.token_hash =~ ~r/^[0-9a-f]{64}$/
      refute Map.has_key?(token, :plaintext)
    end

    test "expires 24 hours after creation", %{user: user} do
      {_plaintext, token} = Accounts.create_session_token(user)

      assert_in_delta DateTime.diff(token.expires_at, DateTime.utc_now(), :second),
                      24 * 60 * 60,
                      5
    end
  end

  describe "get_user_by_api_session_token/1" do
    setup do
      user = user_fixture()
      {plaintext, token} = Accounts.create_session_token(user)
      %{user: user, plaintext: plaintext, token: token}
    end

    test "returns the user for a valid unexpired token", %{user: user, plaintext: plaintext} do
      assert %{id: id} = Accounts.get_user_by_api_session_token(plaintext)
      assert id == user.id
    end

    test "returns nil for an unknown token" do
      refute Accounts.get_user_by_api_session_token("dzst_unknown")
    end

    test "returns nil for an expired token", %{plaintext: plaintext, token: token} do
      expire_session_token(token)
      refute Accounts.get_user_by_api_session_token(plaintext)
    end
  end

  describe "delete_session_token/1" do
    setup do
      user = user_fixture()
      {plaintext, token} = Accounts.create_session_token(user)
      %{user: user, plaintext: plaintext, token: token}
    end

    test "deletes the presented token", %{plaintext: plaintext} do
      assert :ok = Accounts.delete_session_token(plaintext)
      refute Accounts.get_user_by_api_session_token(plaintext)
      assert Repo.all(SessionToken) == []
    end

    test "returns an error for an unknown token" do
      assert :error = Accounts.delete_session_token("dzst_unknown")
    end
  end

  describe "delete_expired_session_tokens/0" do
    test "removes only expired tokens" do
      user = user_fixture()
      {_live_plaintext, _live} = Accounts.create_session_token(user)
      {_expired_plaintext, expired} = Accounts.create_session_token(user)
      expire_session_token(expired)

      assert {1, _} = Accounts.delete_expired_session_tokens()
      assert [%SessionToken{}] = Repo.all(SessionToken)
    end
  end

  describe "password changes and session tokens" do
    test "password reset deletes the user's session tokens" do
      user = user_fixture()
      {plaintext, _} = Accounts.create_session_token(user)

      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})

      refute Accounts.get_user_by_api_session_token(plaintext)
    end

    test "password change deletes the user's session tokens" do
      user = user_fixture()
      {plaintext, _} = Accounts.create_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      refute Accounts.get_user_by_api_session_token(plaintext)
    end

    test "other users' session tokens survive" do
      user = user_fixture()
      other = user_fixture()
      {other_plaintext, _} = Accounts.create_session_token(other)

      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})

      assert Accounts.get_user_by_api_session_token(other_plaintext)
    end
  end

  describe "cleanup worker" do
    test "deletes expired tokens when performed" do
      user = user_fixture()
      {_plaintext, token} = Accounts.create_session_token(user)
      expire_session_token(token)

      assert :ok = perform_job(DarkZenith.Workers.SessionTokenCleanup, %{})
      assert Repo.all(SessionToken) == []
    end
  end

  defp perform_job(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: DarkZenith.Repo)
  end

  defp expire_session_token(token) do
    past = DateTime.add(DateTime.utc_now(:second), -61, :second)

    {1, _} =
      Repo.update_all(
        from(t in SessionToken, where: t.id == ^token.id),
        set: [expires_at: past]
      )
  end
end
