defmodule DarkZenithWeb.Api.V1.PackageControllerTest do
  use DarkZenithWeb.ConnCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures
  import Ecto.Query

  alias DarkZenith.Accounts
  alias DarkZenith.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: true})
    %{conn: conn, owner: owner, repo: repo}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp session_token_for(user) do
    {plaintext, _} = Accounts.create_session_token(user)
    plaintext
  end

  defp api_key_for(user, scopes) do
    {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "k", scopes: scopes})
    plaintext
  end

  defp seed_versions(repo) do
    for version <- ["1.0", "2.0", "10.0"] do
      insert_package_from_rpm!(repo, minimal_binary(), %{
        name: "multi",
        version: version,
        release: "1",
        epoch: 0
      })
    end
  end

  describe "GET /api/v1/repos/:slug/packages" do
    test "lists with the default name/EVR ordering", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_binary())
      seed_versions(repo)

      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages")
      assert %{"data" => data, "pagination" => %{"total" => "4"}} = json_response(conn, 200)

      names = Enum.map(data, & &1["name"])
      assert names == ["dz-fixture", "multi", "multi", "multi"]

      # EVR descending: 10.0 sorts above 2.0 (RPM, not lexical, semantics).
      versions = data |> Enum.filter(&(&1["name"] == "multi")) |> Enum.map(& &1["version"])
      assert versions == ["10.0", "2.0", "1.0"]

      [first | _] = data
      assert first["epoch"] == "2"
      assert first["download_path"] =~ "/repos/#{repo.slug}/packages/"
      assert first["download_path"] =~ "dz-fixture-1.2.3-4.noarch.rpm"
    end

    test "version sort ascending and descending flips only EVR", %{conn: conn, repo: repo} do
      seed_versions(repo)

      asc = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages?sort=version")
      versions = for %{"version" => v} <- json_response(asc, 200)["data"], do: v
      assert versions == ["1.0", "2.0", "10.0"]

      desc = get(build_conn(), ~p"/api/v1/repos/#{repo.slug}/packages?sort=-version")
      versions = for %{"version" => v} <- json_response(desc, 200)["data"], do: v
      assert versions == ["10.0", "2.0", "1.0"]
    end

    test "q matches name or summary with literal pattern characters", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, minimal_binary(), %{name: "prefix_x50", version: "9"})
      insert_package_from_rpm!(repo, minimal_binary(), %{name: "other", version: "9", summary: "has 50% off"})
      insert_package_from_rpm!(repo, minimal_binary(), %{name: "x500", version: "9"})

      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages?q=50%25")
      names = for %{"name" => n} <- json_response(conn, 200)["data"], do: n
      assert Enum.sort(names) == ["other"]
    end

    test "name and arch filters are exact; blank values are rejected", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_binary())
      seed_versions(repo)

      exact = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages?name=multi")
      assert json_response(exact, 200)["pagination"]["total"] == "3"

      blank = get(build_conn(), ~p"/api/v1/repos/#{repo.slug}/packages?name=%20")
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(blank, 422)
    end

    test "unknown sorts are rejected", %{conn: conn, repo: repo} do
      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages?sort=size")
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "private repositories mask the listing", %{conn: conn, owner: owner} do
      private = repository_fixture(owner, %{is_public: false})
      conn = get(conn, ~p"/api/v1/repos/#{private.slug}/packages")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/repos/:slug/packages/:id" do
    test "returns the detail resource with decimal-string counts", %{conn: conn, repo: repo} do
      package = insert_package_from_rpm!(repo, v4_binary())

      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")
      assert %{"data" => data} = json_response(conn, 200)

      assert data["description"] =~ "Fixture package"
      assert data["size_installed"] == "48"
      assert data["size_archive"] == "588"
      assert data["requires_count"] == "6"
      assert data["files_count"] == "3"
      assert data["changelogs_count"] == "2"
      refute Map.has_key?(data, "storage_path")
      refute Map.has_key?(data, "header_start")
    end

    test "ids under another repository are nonexistent", %{conn: conn, owner: owner, repo: repo} do
      other = repository_fixture(owner, %{is_public: true})
      package = insert_package_from_rpm!(other, v4_binary())

      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "subresources" do
    setup %{repo: repo} do
      %{package: insert_package_from_rpm!(repo, v4_binary())}
    end

    test "requires retain stored order", %{conn: conn, repo: repo, package: package} do
      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}/requires")
      assert %{"data" => data, "pagination" => %{"total" => "6"}} = json_response(conn, 200)
      assert List.first(data)["name"] == "(dz-alt-a or dz-alt-b)"
      assert List.last(data)["name"] == "dz-pre-tool"
    end

    test "files sort by path bytes", %{conn: conn, repo: repo, package: package} do
      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}/files")
      paths = for %{"path" => p} <- json_response(conn, 200)["data"], do: p
      assert paths == Enum.sort(paths)
    end

    test "changelogs sort newest first", %{conn: conn, repo: repo, package: package} do
      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}/changelogs")
      assert %{"data" => [first, second]} = json_response(conn, 200)
      assert first["text"] =~ "Second changelog"
      assert second["text"] =~ "First changelog"
    end

    test "pagination applies to subresources", %{conn: conn, repo: repo, package: package} do
      conn =
        get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}/requires?per_page=2&page=2")

      assert %{"data" => data, "pagination" => pagination} = json_response(conn, 200)
      assert length(data) == 2
      assert pagination["total_pages"] == "3"
    end

    test "unknown collections are not found", %{conn: conn, repo: repo, package: package} do
      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}/payload")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/repos/:slug/packages/:id" do
    test "deletes with counters, quota, and cleanup jobs", %{conn: conn, owner: owner, repo: repo} do
      package = insert_package_from_rpm!(repo, v4_binary())
      sync_repository_metadata_state!(repo)

      {1, _} =
        Repo.update_all(from(u in DarkZenith.Accounts.User, where: u.id == ^owner.id),
          set: [storage_bytes: package.size_package]
        )

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")

      assert response(conn, 204) == ""
      refute Repo.get(DarkZenith.Packages.Package, package.id)

      repo_row = Repo.get!(DarkZenith.Repositories.Repository, repo.id)
      assert repo_row.package_count == 0
      empty = DarkZenith.Repodata.document_overhead(0)
      assert repo_row.primary_open_bytes == empty.primary

      assert Repo.get!(DarkZenith.Accounts.User, owner.id).storage_bytes == 0

      assert_enqueued(worker: DarkZenith.Workers.MetadataRegeneration)

      assert_enqueued(
        worker: DarkZenith.Workers.FinalVersionCleanup,
        args: %{storage_path: package.storage_path}
      )
    end

    test "requires package:delete on API keys", %{conn: conn, owner: owner, repo: repo} do
      package = insert_package_from_rpm!(repo, v4_binary())
      sync_repository_metadata_state!(repo)

      forbidden =
        conn
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> delete(~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      ok =
        build_conn()
        |> bearer(api_key_for(owner, ["package:delete"]))
        |> delete(~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")

      assert response(ok, 204) == ""
    end

    test "strangers get 401 on public repos; anonymity never deletes", %{conn: conn, repo: repo} do
      package = insert_package_from_rpm!(repo, v4_binary())

      conn = delete(conn, ~p"/api/v1/repos/#{repo.slug}/packages/#{package.id}")
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end
  end
end
