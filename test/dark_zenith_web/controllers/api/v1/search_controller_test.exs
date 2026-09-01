defmodule DarkZenithWeb.Api.V1.SearchControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    %{conn: conn, owner: user_fixture()}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp api_key_for(user, scopes) do
    {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "k", scopes: scopes})
    plaintext
  end

  defp session_token_for(user) do
    {plaintext, _} = Accounts.create_session_token(user)
    plaintext
  end

  defp insert_package!(repository, overrides) do
    insert_package_from_rpm!(
      repository,
      DarkZenith.RpmFixtures.minimal_binary(),
      Map.new(overrides)
    )
  end

  describe "GET /api/v1/search/packages query validation" do
    test "q is required and must be non-blank", %{conn: conn} do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"q" => [_]}}} =
               conn |> get(~p"/api/v1/search/packages") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"q" => [_]}}} =
               build_conn() |> get("/api/v1/search/packages?q=%20%20") |> json_response(422)
    end

    test "an over-long q is rejected", %{conn: conn} do
      q = String.duplicate("a", 257)

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"q" => [_]}}} =
               conn |> get(~p"/api/v1/search/packages?#{[q: q]}") |> json_response(422)
    end

    test "name and sort are not supported parameters", %{conn: conn} do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"name" => [_]}}} =
               conn |> get(~p"/api/v1/search/packages?q=x&name=y") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"sort" => [_]}}} =
               build_conn()
               |> get(~p"/api/v1/search/packages?q=x&sort=name")
               |> json_response(422)
    end

    test "a blank arch is rejected", %{conn: conn} do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"arch" => [_]}}} =
               build_conn() |> get("/api/v1/search/packages?q=x&arch=%20") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn |> get(~p"/api/v1/search/packages?q=x&page=0") |> json_response(422)
    end
  end

  describe "GET /api/v1/search/packages results" do
    test "rows have the package list shape plus repository_slug", %{conn: conn, owner: owner} do
      repository = repository_fixture(owner, %{is_public: true})
      package = insert_package!(repository, name: "dz-api-shape", summary: "s")

      conn = get(conn, ~p"/api/v1/search/packages?q=dz-api-shape")

      assert %{"data" => [row], "pagination" => pagination} = json_response(conn, 200)
      assert row["id"] == package.id
      assert row["repository_id"] == repository.id
      assert row["repository_slug"] == repository.slug
      assert row["name"] == "dz-api-shape"
      assert row["epoch"] == "0"
      assert row["size_package"] == Integer.to_string(package.size_package)

      assert row["download_path"] ==
               "/repos/#{repository.slug}/packages/#{package.id}/" <>
                 "dz-api-shape-#{package.version}-#{package.release}.#{package.arch}.rpm"

      refute Map.has_key?(row, "storage_path")
      assert pagination == %{"page" => 1, "per_page" => 50, "total" => "1", "total_pages" => "1"}
    end

    test "results follow name, arch, EVR desc, slug ordering and paginate", %{
      conn: conn,
      owner: owner
    } do
      repo_b = repository_fixture(owner, %{slug: "search-ord-b", is_public: true})
      repo_a = repository_fixture(owner, %{slug: "search-ord-a", is_public: true})

      in_b = insert_package!(repo_b, name: "dz-api-ord", version: "1.0")
      in_a = insert_package!(repo_a, name: "dz-api-ord", version: "1.0")
      newer = insert_package!(repo_a, name: "dz-api-ord", version: "1.10")

      conn = get(conn, ~p"/api/v1/search/packages?q=dz-api-ord&per_page=2")

      assert %{"data" => [first, second], "pagination" => pagination} = json_response(conn, 200)
      assert first["id"] == newer.id
      assert second["id"] == in_a.id
      assert pagination["total"] == "3"
      assert pagination["total_pages"] == "2"

      assert %{"data" => [third]} =
               build_conn()
               |> get(~p"/api/v1/search/packages?q=dz-api-ord&per_page=2&page=2")
               |> json_response(200)

      assert third["id"] == in_b.id
    end

    test "arch filters exactly", %{conn: conn, owner: owner} do
      repository = repository_fixture(owner, %{is_public: true})
      x86 = insert_package!(repository, name: "dz-api-arch", arch: "x86_64")
      _noarch = insert_package!(repository, name: "dz-api-arch", version: "9", arch: "noarch")

      conn = get(conn, ~p"/api/v1/search/packages?q=dz-api-arch&arch=x86_64")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["id"] == x86.id
    end
  end

  describe "GET /api/v1/search/packages visibility" do
    setup %{owner: owner} do
      public_repo = repository_fixture(owner, %{is_public: true})
      private_repo = repository_fixture(owner, %{is_public: false})

      %{
        public_repo: public_repo,
        private_repo: private_repo,
        public_package: insert_package!(public_repo, name: "dz-api-vis-pub", summary: "s"),
        private_package: insert_package!(private_repo, name: "dz-api-vis-priv", summary: "s")
      }
    end

    defp result_ids(conn) do
      %{"data" => data} = json_response(conn, 200)
      Enum.map(data, & &1["id"])
    end

    test "anonymous requests search public repositories only", ctx do
      ids = ctx.conn |> get(~p"/api/v1/search/packages?q=dz-api-vis") |> result_ids()
      assert ctx.public_package.id in ids
      refute ctx.private_package.id in ids
    end

    test "API keys without repo:read search public repositories only", ctx do
      ids =
        ctx.conn
        |> bearer(api_key_for(ctx.owner, ["repo:create"]))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.public_package.id in ids
      refute ctx.private_package.id in ids
    end

    test "API keys with repo:read search accessible private repositories", ctx do
      ids =
        ctx.conn
        |> bearer(api_key_for(ctx.owner, ["repo:read"]))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.public_package.id in ids
      assert ctx.private_package.id in ids
    end

    test "session tokens search every accessible repository", ctx do
      ids =
        ctx.conn
        |> bearer(session_token_for(ctx.owner))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.private_package.id in ids
    end

    test "unrelated users never see private rows", ctx do
      ids =
        ctx.conn
        |> bearer(session_token_for(user_fixture()))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.public_package.id in ids
      refute ctx.private_package.id in ids
    end

    test "collaborators see collaborated private rows", ctx do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(ctx.private_repo, collaborator)

      ids =
        ctx.conn
        |> bearer(session_token_for(collaborator))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.private_package.id in ids
    end

    test "admins search all repositories", ctx do
      ids =
        ctx.conn
        |> bearer(session_token_for(admin_fixture()))
        |> get(~p"/api/v1/search/packages?q=dz-api-vis")
        |> result_ids()

      assert ctx.public_package.id in ids
      assert ctx.private_package.id in ids
    end
  end
end
