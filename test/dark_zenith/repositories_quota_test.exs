defmodule DarkZenith.RepositoriesQuotaTest do
  # Not async: temporarily lowers the global max_user_repositories setting.
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Repositories

  setup do
    previous = Application.get_env(:dark_zenith, :max_user_repositories)
    Application.put_env(:dark_zenith, :max_user_repositories, 2)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_user_repositories, previous) end)
    %{owner: user_fixture()}
  end

  test "creation past the limit returns a quota error", %{owner: owner} do
    repository_fixture(owner)
    repository_fixture(owner)

    assert {:error, :quota_exceeded} =
             Repositories.create_repository(owner, valid_repository_attributes())
  end

  test "admins are not exempt" do
    admin = admin_fixture()
    repository_fixture(admin)
    repository_fixture(admin)

    assert {:error, :quota_exceeded} =
             Repositories.create_repository(admin, valid_repository_attributes())
  end

  test "only live repositories count; deletion frees a slot immediately", %{owner: owner} do
    repository_fixture(owner)
    doomed = repository_fixture(owner)

    assert {:error, :quota_exceeded} =
             Repositories.create_repository(owner, valid_repository_attributes())

    :ok = Repositories.delete_repository(owner, doomed)

    assert {:ok, _} = Repositories.create_repository(owner, valid_repository_attributes())
  end

  test "zero disables the limit", %{owner: owner} do
    Application.put_env(:dark_zenith, :max_user_repositories, 0)

    repository_fixture(owner)
    repository_fixture(owner)
    repository_fixture(owner)

    assert {:ok, _} = Repositories.create_repository(owner, valid_repository_attributes())
  end
end
