defmodule DarkZenith.Collaborators.ConversionTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Workers.CollaboratorMailer

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  describe "conversion at account creation" do
    test "registration converts pending invitations into collaborators", ctx do
      email = unique_user_email()
      other_repo = repository_fixture(ctx.owner)

      {:ok, :created, queued} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)
      {:ok, :created, sent} = Collaborators.add_collaborator(ctx.owner, other_repo, email)

      sent_at = DateTime.utc_now(:second)

      Repo.update_all(from(i in Invitation, where: i.id == ^sent.id),
        set: [notification_status: "sent", notification_sent_at: sent_at]
      )

      {:ok, user} = Accounts.register_user(%{email: email, password: valid_user_password()})

      assert Repo.all(from(i in Invitation, where: i.email == ^email)) == []

      queued_collab =
        Repo.get_by!(Collaborator, repository_id: ctx.repo.id, user_id: user.id)

      # A queued invitation becomes a queued collaborator at generation + 1.
      assert queued_collab.notification_status == "queued"
      assert queued_collab.notification_generation == queued.notification_generation + 1
      assert is_nil(queued_collab.notification_sent_at)

      assert_enqueued(
        worker: CollaboratorMailer,
        args: %{
          collaborator_id: queued_collab.id,
          notification_generation: queued_collab.notification_generation
        }
      )

      # A sent invitation carries status, generation, and sent time; no new
      # direct-link message is queued.
      sent_collab =
        Repo.get_by!(Collaborator, repository_id: other_repo.id, user_id: user.id)

      assert sent_collab.notification_status == "sent"
      assert sent_collab.notification_generation == sent.notification_generation
      assert sent_collab.notification_sent_at == sent_at

      refute_enqueued(
        worker: CollaboratorMailer,
        args: %{collaborator_id: sent_collab.id}
      )

      assert Enum.count(Audit.list_events(), &(&1.action == "invitation.convert")) == 2
    end

    test "expired invitations are skipped and deleted, never converted", ctx do
      email = unique_user_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id), set: [expires_at: past])

      {:ok, user} = Accounts.register_user(%{email: email, password: valid_user_password()})

      refute Repo.get(Invitation, invitation.id)
      refute Repo.get_by(Collaborator, repository_id: ctx.repo.id, user_id: user.id)
    end

    test "registration itself is audited", _ctx do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(%{email: email, password: valid_user_password()})

      assert Enum.any?(
               Audit.list_events(),
               &(&1.action == "auth.register" and &1.target_id == user.id)
             )
    end
  end

  describe "conversion at confirmed email change" do
    defp change_email_token(user, new_email) do
      extract_user_token(fn url ->
        Accounts.deliver_user_update_email_instructions(
          %{user | email: new_email},
          user.email,
          url
        )
      end)
    end

    test "pending invitations for the new email convert on confirmation", ctx do
      user = user_fixture()
      new_email = unique_user_email()
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, new_email)

      token = change_email_token(user, new_email)
      assert {:ok, %{email: ^new_email}} = Accounts.update_user_email(user, token)

      assert Repo.get_by(Collaborator, repository_id: ctx.repo.id, user_id: user.id)
      assert Repo.all(from(i in Invitation, where: i.email == ^new_email)) == []
    end

    test "an invitation on a repository where the user is already a collaborator is dropped", ctx do
      user = user_fixture()
      {:ok, :created, existing} = Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      new_email = unique_user_email()
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, new_email)

      before_jobs = length(all_enqueued(worker: CollaboratorMailer))

      token = change_email_token(user, new_email)
      assert {:ok, _} = Accounts.update_user_email(user, token)

      # The invitation is deleted without modifying the existing row or
      # queuing any notification.
      assert Repo.all(from(i in Invitation, where: i.email == ^new_email)) == []
      unchanged = Repo.get!(Collaborator, existing.id)
      assert unchanged.notification_generation == existing.notification_generation
      assert length(all_enqueued(worker: CollaboratorMailer)) == before_jobs
    end

    test "an invitation on a repository the user owns is dropped without a collaborator row", ctx do
      new_email = unique_user_email()
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, new_email)

      token = change_email_token(ctx.owner, new_email)
      assert {:ok, _} = Accounts.update_user_email(ctx.owner, token)

      assert Repo.all(from(i in Invitation, where: i.email == ^new_email)) == []
      refute Repo.get_by(Collaborator, repository_id: ctx.repo.id, user_id: ctx.owner.id)
    end

    test "the email change is audited", _ctx do
      user = user_fixture()
      new_email = unique_user_email()
      token = change_email_token(user, new_email)

      assert {:ok, _} = Accounts.update_user_email(user, token)

      assert Enum.any?(
               Audit.list_events(),
               &(&1.action == "auth.email_change" and &1.target_id == user.id)
             )
    end
  end
end
