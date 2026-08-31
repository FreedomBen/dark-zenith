defmodule DarkZenith.Collaborators.SchemaTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Repo

  setup do
    owner = user_fixture()
    %{owner: owner, other: user_fixture(), repo: repository_fixture(owner)}
  end

  describe "collaborators table constraints" do
    test "one row per (repository, user)", ctx do
      collaborator_row_fixture(ctx.repo, ctx.other)

      assert_raise Ecto.ConstraintError, ~r/collaborators_repository_id_user_id_index/, fn ->
        collaborator_row_fixture(ctx.repo, ctx.other)
      end
    end

    test "notification status is constrained and has no suppressed state", ctx do
      assert_raise Ecto.ConstraintError, ~r/collaborators_notification_status/, fn ->
        collaborator_row_fixture(ctx.repo, ctx.other, %{notification_status: "suppressed"})
      end
    end

    test "generation must be positive", ctx do
      assert_raise Ecto.ConstraintError, ~r/collaborators_notification_generation_positive/, fn ->
        collaborator_row_fixture(ctx.repo, ctx.other, %{notification_generation: 0})
      end
    end

    test "sent requires notification_sent_at; queued and failed require null", ctx do
      assert_raise Ecto.ConstraintError, ~r/collaborators_sent_at_matches_status/, fn ->
        collaborator_row_fixture(ctx.repo, ctx.other, %{notification_status: "sent"})
      end

      assert_raise Ecto.ConstraintError, ~r/collaborators_sent_at_matches_status/, fn ->
        collaborator_row_fixture(ctx.repo, ctx.other, %{
          notification_status: "queued",
          notification_sent_at: DateTime.utc_now(:second)
        })
      end

      collaborator_row_fixture(ctx.repo, ctx.other, %{
        notification_status: "sent",
        notification_sent_at: DateTime.utc_now(:second)
      })
    end

    test "rows are removed when the repository or the collaborator user is deleted", ctx do
      row = collaborator_row_fixture(ctx.repo, ctx.other)

      Repo.delete!(ctx.other)
      refute Repo.get(Collaborator, row.id)

      user = user_fixture()
      row = collaborator_row_fixture(ctx.repo, user)
      Repo.delete!(Repo.get!(DarkZenith.Repositories.Repository, ctx.repo.id))
      refute Repo.get(Collaborator, row.id)
    end
  end

  describe "collaborator_invitations table constraints" do
    test "one row per (repository, email)", ctx do
      invitation = invitation_row_fixture(ctx.repo, ctx.owner)

      assert_raise Ecto.ConstraintError, ~r/collaborator_invitations_repository_id_email_index/, fn ->
        invitation_row_fixture(ctx.repo, ctx.owner, %{email: invitation.email})
      end
    end

    test "notification status includes suppressed and is constrained", ctx do
      invitation_row_fixture(ctx.repo, ctx.owner, %{
        notification_status: "suppressed",
        notification_generation: 0
      })

      assert_raise Ecto.ConstraintError, ~r/collaborator_invitations_notification_status/, fn ->
        invitation_row_fixture(ctx.repo, ctx.owner, %{notification_status: "bogus"})
      end
    end

    test "generation must be non-negative", ctx do
      assert_raise Ecto.ConstraintError,
                   ~r/collaborator_invitations_notification_generation_non_negative/,
                   fn ->
                     invitation_row_fixture(ctx.repo, ctx.owner, %{notification_generation: -1})
                   end
    end

    test "sent requires notification_sent_at; other states require null", ctx do
      assert_raise Ecto.ConstraintError, ~r/collaborator_invitations_sent_at_matches_status/, fn ->
        invitation_row_fixture(ctx.repo, ctx.owner, %{notification_status: "sent"})
      end

      assert_raise Ecto.ConstraintError, ~r/collaborator_invitations_sent_at_matches_status/, fn ->
        invitation_row_fixture(ctx.repo, ctx.owner, %{
          notification_status: "failed",
          notification_sent_at: DateTime.utc_now(:second)
        })
      end
    end

    test "rows are removed when the repository or the inviting user is deleted", ctx do
      row = invitation_row_fixture(ctx.repo, ctx.owner)
      Repo.delete!(Repo.get!(DarkZenith.Repositories.Repository, ctx.repo.id))
      refute Repo.get(Invitation, row.id)

      # Deleting the inviter cascades invitations they sent (User Lifecycle).
      inviter = user_fixture()
      other_repo = repository_fixture(ctx.other)
      row2 = invitation_row_fixture(other_repo, inviter)
      Repo.delete!(inviter)
      refute Repo.get(Invitation, row2.id)
    end
  end
end
