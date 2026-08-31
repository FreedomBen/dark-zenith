defmodule DarkZenith.Collaborators.QuotaTest do
  # Not async: temporarily lowers the global max_repository_collaborators
  # setting (DESIGN.md: Repository Collaborators quota rules).
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.Invitation

  setup do
    previous = Application.get_env(:dark_zenith, :max_repository_collaborators)
    Application.put_env(:dark_zenith, :max_repository_collaborators, 2)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_repository_collaborators, previous) end)

    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp fill_to_limit(ctx) do
    {:ok, :created, _} =
      Collaborators.add_collaborator(ctx.owner, ctx.repo, user_fixture().email)

    {:ok, :created, invitation} =
      Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

    invitation
  end

  test "a new row past the limit is rejected for collaborators and invitations", ctx do
    fill_to_limit(ctx)

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, user_fixture().email)

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())
  end

  test "expired-but-uncleaned invitations still occupy their slot", ctx do
    invitation = fill_to_limit(ctx)

    past = DateTime.add(DateTime.utc_now(:second), -1, :day)
    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), set: [expires_at: past])

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())
  end

  test "idempotent returns and expiry refreshes are never quota-checked", ctx do
    invitation = fill_to_limit(ctx)

    # Idempotent return at the limit.
    assert {:ok, :existing, _} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, invitation.email)

    # Expiry refresh at the limit.
    past = DateTime.add(DateTime.utc_now(:second), -1, :day)
    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), set: [expires_at: past])

    assert {:ok, :existing, refreshed} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, invitation.email)

    assert DateTime.compare(refreshed.expires_at, DateTime.utc_now(:second)) == :gt
  end

  test "removal and cancellation stay available and free slots at the limit", ctx do
    invitation = fill_to_limit(ctx)

    assert :ok = Collaborators.cancel_invitation(ctx.owner, ctx.repo, invitation.id)

    assert {:ok, :created, _} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())
  end

  test "admins are not exempt", ctx do
    fill_to_limit(ctx)
    admin = admin_fixture()

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(admin, ctx.repo, user_fixture().email)
  end

  test "a lowered limit blocks additions but not listing, removal, or cancellation", ctx do
    Application.put_env(:dark_zenith, :max_repository_collaborators, 10)
    fill_to_limit(ctx)

    {:ok, :created, third} =
      Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

    Application.put_env(:dark_zenith, :max_repository_collaborators, 2)

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

    assert length(Collaborators.list_rows(ctx.repo)) == 3
    assert :ok = Collaborators.cancel_invitation(ctx.owner, ctx.repo, third.id)
  end

  test "zero disables the limit", ctx do
    Application.put_env(:dark_zenith, :max_repository_collaborators, 0)

    for _ <- 1..3 do
      assert {:ok, :created, _} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())
    end
  end

  test "conversion is exempt because it deletes the invitation it replaces", ctx do
    email = "convertee#{System.unique_integer([:positive])}@example.com"
    {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    {:ok, :created, _} =
      Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

    assert {:error, :quota_exceeded} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

    {:ok, user} =
      DarkZenith.Accounts.register_user(%{email: email, password: valid_user_password()})

    assert DarkZenith.Repo.get_by(DarkZenith.Collaborators.Collaborator,
             repository_id: ctx.repo.id,
             user_id: user.id
           )
  end

  test "simultaneous adds at the last slot serialize; only one crosses", ctx do
    {:ok, :created, _} =
      Collaborators.add_collaborator(ctx.owner, ctx.repo, user_fixture().email)

    emails = [unique_invited_email(), unique_invited_email()]

    results =
      emails
      |> Enum.map(fn email ->
        Task.async(fn -> Collaborators.add_collaborator(ctx.owner, ctx.repo, email) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, :created, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :quota_exceeded}, &1)) == 1
  end
end
