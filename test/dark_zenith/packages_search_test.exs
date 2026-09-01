defmodule DarkZenith.PackagesSearchTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Packages

  defp insert_package!(repository, overrides) do
    insert_package_from_rpm!(
      repository,
      DarkZenith.RpmFixtures.minimal_binary(),
      Map.new(overrides)
    )
  end

  defp search(user, opts) do
    Repo.all(Packages.search_query(user, opts))
  end

  defp search_ids(user, opts) do
    search(user, opts) |> Enum.map(& &1.package.id)
  end

  describe "search_query/2 matching" do
    setup do
      owner = user_fixture()
      repository = repository_fixture(owner, %{is_public: true})
      %{owner: owner, repository: repository}
    end

    test "matches name and summary case-insensitively", %{repository: repository} do
      by_name = insert_package!(repository, name: "zenith-tool", summary: "unrelated words")

      by_summary =
        insert_package!(repository, name: "other", summary: "The ZENITH helper library")

      _miss = insert_package!(repository, name: "misc", summary: "nothing relevant")

      ids = search_ids(nil, q: "Zenith")
      assert Enum.sort(ids) == Enum.sort([by_name.id, by_summary.id])
    end

    test "treats %, _, and the escape character as literals", %{repository: repository} do
      underscore = insert_package!(repository, name: "a_b", summary: "s1")
      _lookalike = insert_package!(repository, name: "axb", summary: "s2")
      percent = insert_package!(repository, name: "pct", summary: "100% coverage")
      backslash = insert_package!(repository, name: "bsl", summary: ~S(path C:\tmp here))

      assert search_ids(nil, q: "a_b") == [underscore.id]
      assert search_ids(nil, q: "100%") == [percent.id]
      assert search_ids(nil, q: ~S(C:\tmp)) == [backslash.id]
    end

    test "filters by exact arch", %{repository: repository} do
      x86 = insert_package!(repository, name: "dz-arch", arch: "x86_64")
      _noarch = insert_package!(repository, name: "dz-arch", version: "9", arch: "noarch")

      assert search_ids(nil, q: "dz-arch", arch: "x86_64") == [x86.id]
      assert search_ids(nil, q: "dz-arch", arch: "x86") == []
    end

    test "rows carry the package and its repository", %{repository: repository} do
      package = insert_package!(repository, name: "shape-check", summary: "s")

      assert [%{package: found, repository: found_repo}] = search(nil, q: "shape-check")
      assert found.id == package.id
      assert found_repo.id == repository.id
      assert found_repo.slug == repository.slug
    end
  end

  describe "search_query/2 ordering" do
    test "orders by name, arch, EVR descending, repository slug, then id" do
      owner = user_fixture()
      repo_b = repository_fixture(owner, %{slug: "b-repo", is_public: true})
      repo_a = repository_fixture(owner, %{slug: "a-repo", is_public: true})

      # Same name/arch/EVR in two repos: slug breaks the tie.
      in_b = insert_package!(repo_b, name: "dz-ord", version: "1.0", arch: "noarch")
      in_a = insert_package!(repo_a, name: "dz-ord", version: "1.0", arch: "noarch")

      # EVR descending within a name/arch: 1.10 sorts above 1.9 (rpm semantics).
      newer = insert_package!(repo_a, name: "dz-ord", version: "1.10", arch: "noarch")
      older = insert_package!(repo_a, name: "dz-ord", version: "1.9", arch: "noarch")

      # Arch ascending after name.
      src = insert_package!(repo_a, name: "dz-ord", version: "1.0", arch: "src")

      # Name ascending first.
      zz = insert_package!(repo_a, name: "zz-ord", version: "9", arch: "noarch")

      assert search_ids(nil, q: "-ord") ==
               [newer.id, older.id, in_a.id, in_b.id, src.id, zz.id]
    end
  end

  describe "search_query/2 visibility" do
    setup do
      owner = user_fixture()
      public_repo = repository_fixture(owner, %{is_public: true})
      private_repo = repository_fixture(owner, %{is_public: false})

      public_package = insert_package!(public_repo, name: "dz-vis-public", summary: "s")
      private_package = insert_package!(private_repo, name: "dz-vis-private", summary: "s")

      %{
        owner: owner,
        public_repo: public_repo,
        private_repo: private_repo,
        public_package: public_package,
        private_package: private_package
      }
    end

    test "anonymous requesters search public repositories only", ctx do
      ids = search_ids(nil, q: "dz-vis")
      assert ctx.public_package.id in ids
      refute ctx.private_package.id in ids
    end

    test "unrelated users search public repositories only", ctx do
      ids = search_ids(user_fixture(), q: "dz-vis")
      assert ctx.public_package.id in ids
      refute ctx.private_package.id in ids
    end

    test "owners additionally search their private repositories", ctx do
      ids = search_ids(ctx.owner, q: "dz-vis")
      assert ctx.public_package.id in ids
      assert ctx.private_package.id in ids
    end

    test "collaborators additionally search collaborated private repositories", ctx do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(ctx.private_repo, collaborator)

      other_private = repository_fixture(ctx.owner, %{is_public: false})
      hidden = insert_package!(other_private, name: "dz-vis-hidden", summary: "s")

      ids = search_ids(collaborator, q: "dz-vis")
      assert ctx.public_package.id in ids
      assert ctx.private_package.id in ids
      refute hidden.id in ids
    end

    test "admins search all repositories", ctx do
      ids = search_ids(admin_fixture(), q: "dz-vis")
      assert ctx.public_package.id in ids
      assert ctx.private_package.id in ids
    end
  end
end
