defmodule DarkZenith.Collaborators.RegistrationDisabledTest do
  # Not async: flips the global registration_enabled setting to exercise the
  # suppressed-notification rules (DESIGN.md: Repository Collaborators).
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.Invitation
  alias DarkZenith.Workers.InvitationMailer

  setup do
    previous = Application.get_env(:dark_zenith, :registration_enabled)
    Application.put_env(:dark_zenith, :registration_enabled, false)
    on_exit(fn -> Application.put_env(:dark_zenith, :registration_enabled, previous) end)

    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  test "an unregistered invite is created suppressed at generation 0 with no mail", ctx do
    email = unique_invited_email()

    assert {:ok, :created, %Invitation{} = invitation} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    assert invitation.notification_status == "suppressed"
    assert invitation.notification_generation == 0
    assert invitation.expires_at
    assert all_enqueued(worker: InvitationMailer) == []
  end

  test "registered users are still notified directly while registration is disabled", ctx do
    user = user_fixture()

    assert {:ok, :created, collaborator} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

    assert collaborator.notification_status == "queued"
  end

  test "re-adding a suppressed invitation stays suppressed while registration is disabled", ctx do
    email = unique_invited_email()
    {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    assert {:ok, :existing, invitation} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    assert invitation.notification_status == "suppressed"
    assert invitation.notification_generation == 0
    assert all_enqueued(worker: InvitationMailer) == []
  end

  test "re-adding a suppressed invitation queues once registration is enabled", ctx do
    email = unique_invited_email()
    {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    Application.put_env(:dark_zenith, :registration_enabled, true)

    assert {:ok, :existing, requeued} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    assert requeued.notification_status == "queued"
    assert requeued.notification_generation == 1

    assert_enqueued(
      worker: InvitationMailer,
      args: %{invitation_id: invitation.id, notification_generation: 1}
    )
  end

  test "an expired refresh increments the generation but stays suppressed", ctx do
    email = unique_invited_email()
    {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    past = DateTime.add(DateTime.utc_now(:second), -1, :day)
    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), set: [expires_at: past])

    assert {:ok, :existing, refreshed} =
             Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

    assert refreshed.notification_status == "suppressed"
    assert refreshed.notification_generation == 1
    assert DateTime.compare(refreshed.expires_at, DateTime.utc_now(:second)) == :gt
    assert all_enqueued(worker: InvitationMailer) == []
  end
end
