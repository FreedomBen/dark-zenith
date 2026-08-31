defmodule DarkZenith.Collaborators.MailerFailureTest do
  # Not async: injects a failing notifier implementation via the application
  # environment to exercise provider-failure handling (DESIGN.md:
  # Collaborator Invitations delivery state machine).
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Workers.{CollaboratorMailer, InvitationMailer}

  defmodule FailingNotifier do
    def deliver_collaborator_added(_email, _repository), do: {:error, :provider_down}
    def deliver_invitation(_email, _repository), do: {:error, :provider_down}
  end

  setup do
    previous = Application.get_env(:dark_zenith, :collaborator_notifier)
    Application.put_env(:dark_zenith, :collaborator_notifier, FailingNotifier)
    on_exit(fn -> Application.put_env(:dark_zenith, :collaborator_notifier, previous) end)

    owner = user_fixture()
    repo = repository_fixture(owner)

    {:ok, :created, collaborator} =
      Collaborators.add_collaborator(owner, repo, user_fixture().email)

    {:ok, :created, invitation} =
      Collaborators.add_collaborator(
        owner,
        repo,
        "pending#{System.unique_integer([:positive])}@example.com"
      )

    %{collaborator: collaborator, invitation: invitation}
  end

  test "a retryable failure leaves the row queued", ctx do
    assert {:error, :provider_down} =
             perform_job(
               CollaboratorMailer,
               %{"collaborator_id" => ctx.collaborator.id, "notification_generation" => 1},
               attempt: 1
             )

    reloaded = Repo.get!(Collaborator, ctx.collaborator.id)
    assert reloaded.notification_status == "queued"
    assert is_nil(reloaded.notification_sent_at)
  end

  test "the twentieth failed attempt marks the row failed before discard", ctx do
    assert {:error, :provider_down} =
             perform_job(
               InvitationMailer,
               %{"invitation_id" => ctx.invitation.id, "notification_generation" => 1},
               attempt: 20
             )

    assert Repo.get!(Invitation, ctx.invitation.id).notification_status == "failed"

    assert {:error, :provider_down} =
             perform_job(
               CollaboratorMailer,
               %{"collaborator_id" => ctx.collaborator.id, "notification_generation" => 1},
               attempt: 20
             )

    assert Repo.get!(Collaborator, ctx.collaborator.id).notification_status == "failed"
  end

  test "an exhausted attempt for a stale generation does not overwrite newer state", ctx do
    Repo.update_all(from(i in Invitation, where: i.id == ^ctx.invitation.id),
      set: [notification_generation: 2]
    )

    assert :ok =
             perform_job(
               InvitationMailer,
               %{"invitation_id" => ctx.invitation.id, "notification_generation" => 1},
               attempt: 20
             )

    reloaded = Repo.get!(Invitation, ctx.invitation.id)
    assert reloaded.notification_status == "queued"
    assert reloaded.notification_generation == 2
  end
end
