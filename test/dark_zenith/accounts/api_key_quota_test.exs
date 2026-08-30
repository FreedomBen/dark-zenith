defmodule DarkZenith.Accounts.ApiKeyQuotaTest do
  # Not async: temporarily lowers the global max_user_api_keys setting.
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts

  setup do
    previous = Application.get_env(:dark_zenith, :max_user_api_keys)
    Application.put_env(:dark_zenith, :max_user_api_keys, 2)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_user_api_keys, previous) end)
    %{user: user_fixture()}
  end

  test "creation past the limit returns a quota error", %{user: user} do
    {:ok, _} = Accounts.create_api_key(user, %{name: "one", scopes: ["repo:read"]})
    {:ok, _} = Accounts.create_api_key(user, %{name: "two", scopes: ["repo:read"]})

    assert {:error, :quota_exceeded} =
             Accounts.create_api_key(user, %{name: "three", scopes: ["repo:read"]})
  end

  test "expired rows count toward the quota until deleted", %{user: user} do
    {:ok, _} = Accounts.create_api_key(user, %{name: "one", scopes: ["repo:read"]})

    {:ok, {_, expired}} =
      Accounts.create_api_key(user, %{
        name: "two",
        scopes: ["repo:read"],
        expires_at: DateTime.add(DateTime.utc_now(:second), 1, :second)
      })

    past = DateTime.add(DateTime.utc_now(:second), -61, :second)

    {1, _} =
      Repo.update_all(
        from(k in Accounts.ApiKey, where: k.id == ^expired.id),
        set: [expires_at: past]
      )

    assert {:error, :quota_exceeded} =
             Accounts.create_api_key(user, %{name: "three", scopes: ["repo:read"]})
  end

  test "deletion immediately restores capacity", %{user: user} do
    {:ok, _} = Accounts.create_api_key(user, %{name: "one", scopes: ["repo:read"]})
    {:ok, {_, second}} = Accounts.create_api_key(user, %{name: "two", scopes: ["repo:read"]})

    assert {:error, :quota_exceeded} =
             Accounts.create_api_key(user, %{name: "three", scopes: ["repo:read"]})

    :ok = Accounts.delete_api_key(user, second.id)

    assert {:ok, _} = Accounts.create_api_key(user, %{name: "three", scopes: ["repo:read"]})
  end

  test "admins are not exempt", %{user: _user} do
    admin = admin_fixture()

    {:ok, _} = Accounts.create_api_key(admin, %{name: "one", scopes: ["repo:read"]})
    {:ok, _} = Accounts.create_api_key(admin, %{name: "two", scopes: ["repo:read"]})

    assert {:error, :quota_exceeded} =
             Accounts.create_api_key(admin, %{name: "three", scopes: ["repo:read"]})
  end

  test "a lowered limit blocks creation but not listing or deletion", %{user: user} do
    Application.put_env(:dark_zenith, :max_user_api_keys, 100)
    {:ok, _} = Accounts.create_api_key(user, %{name: "one", scopes: ["repo:read"]})
    {:ok, _} = Accounts.create_api_key(user, %{name: "two", scopes: ["repo:read"]})
    {:ok, {_, third}} = Accounts.create_api_key(user, %{name: "three", scopes: ["repo:read"]})

    Application.put_env(:dark_zenith, :max_user_api_keys, 2)

    assert {:error, :quota_exceeded} =
             Accounts.create_api_key(user, %{name: "four", scopes: ["repo:read"]})

    assert length(Accounts.list_api_keys(user)) == 3
    assert :ok = Accounts.delete_api_key(user, third.id)
  end
end
