defmodule DarkZenith.AuthorizationTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Authorization

  setup do
    owner = user_fixture()

    %{
      owner: owner,
      admin: admin_fixture(),
      other: user_fixture(),
      public_repo: repository_fixture(owner, %{is_public: true}),
      private_repo: repository_fixture(owner)
    }
  end

  describe "can_read?/2" do
    test "public repositories are readable by everyone", ctx do
      assert Authorization.can_read?(nil, ctx.public_repo)
      assert Authorization.can_read?(ctx.other, ctx.public_repo)
      assert Authorization.can_read?(ctx.owner, ctx.public_repo)
      assert Authorization.can_read?(ctx.admin, ctx.public_repo)
    end

    test "private repositories admit only owner, collaborators, and admins", ctx do
      refute Authorization.can_read?(nil, ctx.private_repo)
      refute Authorization.can_read?(ctx.other, ctx.private_repo)
      assert Authorization.can_read?(ctx.owner, ctx.private_repo)
      assert Authorization.can_read?(ctx.admin, ctx.private_repo)

      collaborator_row_fixture(ctx.private_repo, ctx.other)
      assert Authorization.can_read?(ctx.other, ctx.private_repo)
    end

    test "a collaborator row on one repository grants nothing on another", ctx do
      collaborator_row_fixture(ctx.private_repo, ctx.other)
      other_private = repository_fixture(ctx.owner)

      refute Authorization.can_read?(ctx.other, other_private)
    end
  end

  describe "can_manage?/2" do
    test "only the owner and admins can manage", ctx do
      assert Authorization.can_manage?(ctx.owner, ctx.private_repo)
      assert Authorization.can_manage?(ctx.admin, ctx.private_repo)
      refute Authorization.can_manage?(ctx.other, ctx.private_repo)
      refute Authorization.can_manage?(nil, ctx.private_repo)
    end

    test "collaborators cannot manage", ctx do
      collaborator_row_fixture(ctx.private_repo, ctx.other)
      refute Authorization.can_manage?(ctx.other, ctx.private_repo)
    end

    test "public visibility does not grant management", ctx do
      refute Authorization.can_manage?(ctx.other, ctx.public_repo)
      refute Authorization.can_manage?(nil, ctx.public_repo)
    end
  end

  describe "collaborator?/2" do
    test "true only for users with a collaborator row", ctx do
      refute Authorization.collaborator?(ctx.other, ctx.private_repo)
      collaborator_row_fixture(ctx.private_repo, ctx.other)
      assert Authorization.collaborator?(ctx.other, ctx.private_repo)
      refute Authorization.collaborator?(ctx.owner, ctx.private_repo)
    end
  end
end
