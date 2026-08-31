defmodule DarkZenith.Collaborators.NotifierTest do
  # Not async: overrides the configured sender via the application
  # environment to prove collaborator mail honors MAIL_FROM_NAME /
  # MAIL_FROM_ADDRESS (DESIGN.md: Email Delivery).
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Collaborators.Notifier

  setup do
    previous = Application.get_env(:dark_zenith, :mail_from)
    Application.put_env(:dark_zenith, :mail_from, {"Configured Name", "configured@sender.test"})

    on_exit(fn ->
      if previous do
        Application.put_env(:dark_zenith, :mail_from, previous)
      else
        Application.delete_env(:dark_zenith, :mail_from)
      end
    end)

    %{repo: repository_fixture(user_fixture())}
  end

  test "collaborator notification uses the configured sender", %{repo: repo} do
    {:ok, email} = Notifier.deliver_collaborator_added("someone@example.com", repo)

    assert email.from == {"Configured Name", "configured@sender.test"}
  end

  test "invitation uses the configured sender", %{repo: repo} do
    {:ok, email} = Notifier.deliver_invitation("someone@example.com", repo)

    assert email.from == {"Configured Name", "configured@sender.test"}
  end
end
