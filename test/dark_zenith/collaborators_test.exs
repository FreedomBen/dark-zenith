defmodule DarkZenith.CollaboratorsTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures
  import Swoosh.TestAssertions

  alias DarkZenith.Audit
  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Workers.{CollaboratorMailer, InvitationMailer}

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  describe "add_collaborator/3 with a registered email" do
    test "creates a queued collaborator at generation 1 and enqueues mail", ctx do
      user = user_fixture()

      assert {:ok, :created, %Collaborator{} = collaborator} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert collaborator.repository_id == ctx.repo.id
      assert collaborator.user_id == user.id
      assert collaborator.notification_status == "queued"
      assert collaborator.notification_generation == 1
      assert is_nil(collaborator.notification_sent_at)

      assert_enqueued(
        worker: CollaboratorMailer,
        args: %{collaborator_id: collaborator.id, notification_generation: 1}
      )

      assert [event | _] = Audit.list_events()
      assert event.action == "collaborator.add"
      assert event.target_type == "collaborator"
      assert event.target_id == collaborator.id
    end

    test "normalizes the email before lookup", ctx do
      user = user_fixture()

      assert {:ok, :created, %Collaborator{user_id: user_id}} =
               Collaborators.add_collaborator(
                 ctx.owner,
                 ctx.repo,
                 "  " <> String.upcase(user.email) <> "  "
               )

      assert user_id == user.id
    end

    test "re-adding a queued or sent collaborator changes nothing and queues nothing", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert {:ok, :existing, unchanged} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert unchanged.id == collaborator.id
      assert unchanged.notification_generation == 1
      assert [_only_one] = all_enqueued(worker: CollaboratorMailer)

      sent_at = DateTime.utc_now(:second)

      Repo.update_all(from(c in Collaborator, where: c.id == ^collaborator.id),
        set: [notification_status: "sent", notification_sent_at: sent_at]
      )

      assert {:ok, :existing, sent_row} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert sent_row.notification_status == "sent"
      assert sent_row.notification_generation == 1
      assert [_still_one] = all_enqueued(worker: CollaboratorMailer)
    end

    test "re-adding a failed collaborator queues a fresh generation", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      Repo.update_all(from(c in Collaborator, where: c.id == ^collaborator.id),
        set: [notification_status: "failed"]
      )

      assert {:ok, :existing, requeued} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert requeued.notification_status == "queued"
      assert requeued.notification_generation == 2
      assert is_nil(requeued.notification_sent_at)

      assert_enqueued(
        worker: CollaboratorMailer,
        args: %{collaborator_id: collaborator.id, notification_generation: 2}
      )
    end

    test "an admin can add collaborators to any private repository", ctx do
      admin = admin_fixture()
      user = user_fixture()

      assert {:ok, :created, %Collaborator{}} =
               Collaborators.add_collaborator(admin, ctx.repo, user.email)
    end
  end

  describe "add_collaborator/3 with an unregistered email" do
    test "creates a queued invitation at generation 1 with expiry", ctx do
      email = unique_invited_email()

      assert {:ok, :created, %Invitation{} = invitation} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert invitation.email == email
      assert invitation.invited_by_id == ctx.owner.id
      assert invitation.notification_status == "queued"
      assert invitation.notification_generation == 1
      assert is_nil(invitation.notification_sent_at)

      expected = DateTime.add(DateTime.utc_now(:second), 30, :day)
      assert_in_delta DateTime.to_unix(invitation.expires_at), DateTime.to_unix(expected), 5

      assert_enqueued(
        worker: InvitationMailer,
        args: %{invitation_id: invitation.id, notification_generation: 1}
      )

      assert [event | _] = Audit.list_events()
      assert event.action == "invitation.create"
      assert event.target_type == "invitation"
      assert event.metadata["email"] == email
    end

    test "re-adding a queued or sent invitation changes nothing", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert {:ok, :existing, unchanged} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert unchanged.id == invitation.id
      assert unchanged.notification_generation == 1
      assert [_only_one] = all_enqueued(worker: InvitationMailer)
    end

    test "re-adding a failed invitation queues a new generation", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [notification_status: "failed"]
      )

      assert {:ok, :existing, requeued} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert requeued.notification_status == "queued"
      assert requeued.notification_generation == 2

      assert_enqueued(
        worker: InvitationMailer,
        args: %{invitation_id: invitation.id, notification_generation: 2}
      )
    end

    test "refreshing an expired invitation resets expiry and always re-queues", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      sent_at = DateTime.add(past, -1, :day)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: past, notification_status: "sent", notification_sent_at: sent_at]
      )

      assert {:ok, :existing, refreshed} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert refreshed.notification_status == "queued"
      assert refreshed.notification_generation == 2
      assert is_nil(refreshed.notification_sent_at)
      assert DateTime.compare(refreshed.expires_at, DateTime.utc_now(:second)) == :gt

      assert_enqueued(
        worker: InvitationMailer,
        args: %{invitation_id: invitation.id, notification_generation: 2}
      )

      assert Enum.any?(Audit.list_events(), &(&1.action == "invitation.expiry_refresh"))
    end

    test "the same email can be invited to two different repositories", ctx do
      email = unique_invited_email()
      other_repo = repository_fixture(ctx.owner)

      assert {:ok, :created, %Invitation{}} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert {:ok, :created, %Invitation{}} =
               Collaborators.add_collaborator(ctx.owner, other_repo, email)
    end
  end

  describe "add_collaborator/3 rejections" do
    test "rejects the repository owner's email", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, ctx.owner.email)

      assert %{email: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Collaborator, :count) == 0
      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "rejects invalid and overlong emails", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, "not an email")

      long = String.duplicate("a", 160) <> "@example.com"

      assert {:error, %Ecto.Changeset{}} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, long)

      assert {:error, %Ecto.Changeset{}} =
               Collaborators.add_collaborator(ctx.owner, ctx.repo, "")
    end

    test "rejects additions on public repositories", ctx do
      public = repository_fixture(ctx.owner, %{is_public: true})
      user = user_fixture()

      assert {:error, :public_repository} =
               Collaborators.add_collaborator(ctx.owner, public, user.email)
    end

    test "non-managers cannot add", ctx do
      outsider = user_fixture()
      user = user_fixture()

      assert {:error, :forbidden} =
               Collaborators.add_collaborator(outsider, ctx.repo, user.email)

      # Collaborators can read but never manage membership.
      collaborator_row_fixture(ctx.repo, outsider)

      assert {:error, :forbidden} =
               Collaborators.add_collaborator(outsider, ctx.repo, user.email)
    end
  end

  describe "list_rows/1" do
    test "returns collaborators and invitations sorted by email, type, id", ctx do
      collab_user = user_fixture(%{email: "bbb#{System.unique_integer([:positive])}@example.com"})
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, collab_user.email)

      a_email = "aaa#{System.unique_integer([:positive])}@example.com"
      z_email = "zzz#{System.unique_integer([:positive])}@example.com"
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, z_email)
      {:ok, :created, _} = Collaborators.add_collaborator(ctx.owner, ctx.repo, a_email)

      rows = Collaborators.list_rows(ctx.repo)

      assert [
               %Invitation{email: ^a_email},
               %Collaborator{} = collaborator,
               %Invitation{email: ^z_email}
             ] = rows

      assert collaborator.user.email == collab_user.email
    end

    test "includes expired invitations until cleanup removes them", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      past = DateTime.add(DateTime.utc_now(:second), -1, :day)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: past]
      )

      assert [%Invitation{id: invitation_id}] = Collaborators.list_rows(ctx.repo)
      assert invitation_id == invitation.id
    end
  end

  describe "remove_collaborator/3 and cancel_invitation/3" do
    test "owner removes a collaborator; the removal is audited", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      assert :ok = Collaborators.remove_collaborator(ctx.owner, ctx.repo, collaborator.id)
      refute Repo.get(Collaborator, collaborator.id)
      assert Enum.any?(Audit.list_events(), &(&1.action == "collaborator.remove"))
    end

    test "owner cancels an invitation; the cancellation is audited", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      assert :ok = Collaborators.cancel_invitation(ctx.owner, ctx.repo, invitation.id)
      refute Repo.get(Invitation, invitation.id)
      assert Enum.any?(Audit.list_events(), &(&1.action == "invitation.cancel"))
    end

    test "ids under a different repository are treated as nonexistent", ctx do
      other_repo = repository_fixture(ctx.owner)
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      {:ok, :created, invitation} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

      assert {:error, :not_found} =
               Collaborators.remove_collaborator(ctx.owner, other_repo, collaborator.id)

      assert {:error, :not_found} =
               Collaborators.cancel_invitation(ctx.owner, other_repo, invitation.id)
    end

    test "non-managers cannot remove or cancel", ctx do
      outsider = user_fixture()
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      {:ok, :created, invitation} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

      assert {:error, :forbidden} =
               Collaborators.remove_collaborator(outsider, ctx.repo, collaborator.id)

      assert {:error, :forbidden} =
               Collaborators.cancel_invitation(outsider, ctx.repo, invitation.id)
    end

    test "rows on a now-public repository can still be listed and removed", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      {:ok, :created, invitation} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, unique_invited_email())

      {:ok, public_repo} =
        DarkZenith.Repositories.update_repository(ctx.owner, ctx.repo, %{"is_public" => true})

      assert length(Collaborators.list_rows(public_repo)) == 2
      assert :ok = Collaborators.remove_collaborator(ctx.owner, public_repo, collaborator.id)
      assert :ok = Collaborators.cancel_invitation(ctx.owner, public_repo, invitation.id)
    end
  end

  # Account fixtures deliver confirmation emails into the test mailbox; drop
  # them so worker assertions see only collaborator/invitation mail.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  describe "mail workers" do
    test "collaborator mail delivery marks the row sent", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      flush_emails()

      assert :ok =
               perform_job(CollaboratorMailer, %{
                 "collaborator_id" => collaborator.id,
                 "notification_generation" => 1
               })

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.text_body =~ "/repos/#{ctx.repo.slug}"
      end)

      reloaded = Repo.get!(Collaborator, collaborator.id)
      assert reloaded.notification_status == "sent"
      assert reloaded.notification_generation == 1
      refute is_nil(reloaded.notification_sent_at)
    end

    test "invitation mail delivery includes a registration link and marks sent", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      flush_emails()

      assert :ok =
               perform_job(InvitationMailer, %{
                 "invitation_id" => invitation.id,
                 "notification_generation" => 1
               })

      assert_email_sent(fn mail ->
        assert mail.to == [{"", email}]
        assert mail.text_body =~ "/users/register"
      end)

      reloaded = Repo.get!(Invitation, invitation.id)
      assert reloaded.notification_status == "sent"
      refute is_nil(reloaded.notification_sent_at)
    end

    test "a stale generation no-ops without sending", ctx do
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(ctx.owner, ctx.repo, user.email)

      Repo.update_all(from(c in Collaborator, where: c.id == ^collaborator.id),
        set: [notification_generation: 2]
      )

      flush_emails()

      assert :ok =
               perform_job(CollaboratorMailer, %{
                 "collaborator_id" => collaborator.id,
                 "notification_generation" => 1
               })

      assert_no_email_sent()
      assert Repo.get!(Collaborator, collaborator.id).notification_status == "queued"
    end

    test "a non-queued status no-ops without sending", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      sent_at = DateTime.utc_now(:second)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [notification_status: "sent", notification_sent_at: sent_at]
      )

      flush_emails()

      assert :ok =
               perform_job(InvitationMailer, %{
                 "invitation_id" => invitation.id,
                 "notification_generation" => 1
               })

      assert_no_email_sent()
    end

    test "a deleted row no-ops", _ctx do
      flush_emails()

      assert :ok =
               perform_job(InvitationMailer, %{
                 "invitation_id" => Ecto.UUID.generate(),
                 "notification_generation" => 1
               })

      assert :ok =
               perform_job(CollaboratorMailer, %{
                 "collaborator_id" => Ecto.UUID.generate(),
                 "notification_generation" => 1
               })

      assert_no_email_sent()
    end

    test "backoff follows the Background Retry Policy curve" do
      for {attempt, expected} <- [{1, 30}, {2, 60}, {8, 3600}, {20, 3600}] do
        job = %Oban.Job{attempt: attempt}
        assert CollaboratorMailer.backoff(job) == expected
        assert InvitationMailer.backoff(job) == expected
      end
    end

    test "duplicate jobs for one generation are unique", ctx do
      email = unique_invited_email()
      {:ok, :created, invitation} = Collaborators.add_collaborator(ctx.owner, ctx.repo, email)

      # A second insert of the same (invitation, generation) is deduplicated.
      %{invitation_id: invitation.id, notification_generation: 1}
      |> InvitationMailer.new()
      |> Oban.insert!()

      assert [_only_one] = all_enqueued(worker: InvitationMailer)
    end
  end

  describe "delete_expired_invitations/0" do
    test "the cleanup worker is scheduled hourly and performs the deletion", ctx do
      plugins = Keyword.fetch!(Application.fetch_env!(:dark_zenith, Oban), :plugins)
      {_, cron_opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {"0 * * * *", DarkZenith.Workers.InvitationCleanup} in Keyword.fetch!(
               cron_opts,
               :crontab
             )

      expired = invitation_row_fixture(ctx.repo, ctx.owner)
      past = DateTime.add(DateTime.utc_now(:second), -1, :second)
      Repo.update_all(from(i in Invitation, where: i.id == ^expired.id), set: [expires_at: past])

      assert :ok = perform_job(DarkZenith.Workers.InvitationCleanup, %{})
      refute Repo.get(Invitation, expired.id)
    end

    test "deletes only expired invitations", ctx do
      expired = invitation_row_fixture(ctx.repo, ctx.owner)
      keep = invitation_row_fixture(ctx.repo, ctx.owner)
      no_expiry = invitation_row_fixture(ctx.repo, ctx.owner, %{expires_at: nil})

      past = DateTime.add(DateTime.utc_now(:second), -1, :second)
      Repo.update_all(from(i in Invitation, where: i.id == ^expired.id), set: [expires_at: past])

      assert {1, _} = Collaborators.delete_expired_invitations()
      refute Repo.get(Invitation, expired.id)
      assert Repo.get(Invitation, keep.id)
      assert Repo.get(Invitation, no_expiry.id)
    end
  end
end
