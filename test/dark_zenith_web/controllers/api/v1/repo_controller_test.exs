defmodule DarkZenithWeb.Api.V1.RepoControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "content-type", "application/json"), owner: user_fixture()}
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

  describe "GET /api/v1/repos" do
    test "anonymous requests list public repositories only", %{conn: conn, owner: owner} do
      public = repository_fixture(owner, %{is_public: true})
      _private = repository_fixture(owner, %{is_public: false})

      conn = get(conn, ~p"/api/v1/repos")

      assert %{"data" => [repo], "pagination" => pagination} = json_response(conn, 200)
      assert repo["id"] == public.id
      assert repo["owner_id"] == owner.id
      refute Map.has_key?(repo, "user_id")
      assert repo["metadata_revision"] == "0"
      assert repo["package_count"] == "0"
      assert pagination == %{"page" => 1, "per_page" => 50, "total" => "1", "total_pages" => "1"}
    end

    test "session tokens list accessible private repositories", %{conn: conn, owner: owner} do
      private = repository_fixture(owner, %{is_public: false})

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> get(~p"/api/v1/repos")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, &(&1["id"] == private.id))
    end

    test "API keys need repo:read to list private repositories", %{conn: conn, owner: owner} do
      private = repository_fixture(owner, %{is_public: false})

      without = conn |> bearer(api_key_for(owner, ["repo:create"])) |> get(~p"/api/v1/repos")
      assert %{"data" => data} = json_response(without, 200)
      refute Enum.any?(data, &(&1["id"] == private.id))

      with_read =
        build_conn()
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> get(~p"/api/v1/repos")

      assert %{"data" => data} = json_response(with_read, 200)
      assert Enum.any?(data, &(&1["id"] == private.id))
    end

    test "pagination is strict", %{conn: conn} do
      assert %{"error" => %{"code" => "validation_failed"}} =
               conn |> get(~p"/api/v1/repos?page=0") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               build_conn() |> get(~p"/api/v1/repos?page=abc") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               build_conn() |> get(~p"/api/v1/repos?page=10001") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               build_conn() |> get(~p"/api/v1/repos?unknown=1") |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed"}} =
               build_conn() |> get(~p"/api/v1/repos?page=1&page=1") |> json_response(422)
    end

    test "per_page is clamped at 100 and a page past the end returns empty data", %{
      conn: conn,
      owner: owner
    } do
      repository_fixture(owner, %{is_public: true})

      conn = get(conn, ~p"/api/v1/repos?per_page=500&page=99")

      assert %{"data" => [], "pagination" => pagination} = json_response(conn, 200)
      assert pagination["per_page"] == 100
      assert pagination["page"] == 99
      assert pagination["total"] == "1"
    end
  end

  describe "POST /api/v1/repos" do
    test "creates a repository for a session-token principal", %{conn: conn, owner: owner} do
      conn =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos", %{"name" => "Stable", "slug" => "api-stable"})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["slug"] == "api-stable"
      assert data["owner_id"] == owner.id
      assert data["rpm_signing_state"] == "disabled"
    end

    test "requires the repo:create scope on API keys", %{conn: conn, owner: owner} do
      denied =
        conn
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> post(~p"/api/v1/repos", %{"name" => "X", "slug" => "denied"})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(denied, 403)

      allowed =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(api_key_for(owner, ["repo:create"]))
        |> post(~p"/api/v1/repos", %{"name" => "X", "slug" => "allowed"})

      assert json_response(allowed, 201)
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/repos", %{"name" => "X", "slug" => "nope"})
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "slug conflicts surface as validation_failed with details.slug", %{
      conn: conn,
      owner: owner
    } do
      repository_fixture(owner, %{slug: "collide"})

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos", %{"name" => "X", "slug" => "collide"})

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"slug" => [_]}}} =
               json_response(conn, 422)
    end

    test "rejects unknown fields and server-managed fields", %{conn: conn, owner: owner} do
      conn =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos", %{
          "name" => "X",
          "slug" => "strict",
          "rpm_signing_state" => "enabled"
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/repos/:slug" do
    test "serves public repositories to anonymous requesters", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner, %{is_public: true, description: "hello"})

      conn = get(conn, ~p"/api/v1/repos/#{repo.slug}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["description"] == "hello"
    end

    test "masks private repositories and unknown slugs identically", %{conn: _conn, owner: owner} do
      repo = repository_fixture(owner, %{is_public: false})
      stranger = user_fixture()

      for build <- [
            fn -> build_conn() end,
            fn -> bearer(build_conn(), session_token_for(stranger)) end,
            fn -> bearer(build_conn(), "Bearerless") end
          ] do
        private = get(build.(), ~p"/api/v1/repos/#{repo.slug}")
        missing = get(build.(), ~p"/api/v1/repos/does-not-exist")

        assert %{"error" => %{"code" => "not_found"}} = json_response(private, 404)
        assert %{"error" => %{"code" => "not_found"}} = json_response(missing, 404)
      end
    end

    test "owners read their private repository", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner, %{is_public: false})

      conn = conn |> bearer(session_token_for(owner)) |> get(~p"/api/v1/repos/#{repo.slug}")
      assert json_response(conn, 200)
    end

    test "an API key without repo:read is masked on private reads", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner, %{is_public: false})

      conn =
        conn
        |> bearer(api_key_for(owner, ["repo:update"]))
        |> get(~p"/api/v1/repos/#{repo.slug}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/repos/:slug" do
    test "owners update settings", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner)

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> patch(~p"/api/v1/repos/#{repo.slug}", %{"name" => "Renamed", "is_public" => true})

      assert %{"data" => %{"name" => "Renamed", "is_public" => true}} = json_response(conn, 200)
    end

    test "requests including slug are rejected", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner)

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> patch(~p"/api/v1/repos/#{repo.slug}", %{"slug" => "other"})

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "an empty object is rejected", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner)

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> patch(~p"/api/v1/repos/#{repo.slug}", %{})

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "API keys need repo:update; a readable repo without the scope is 403", %{
      conn: conn,
      owner: owner
    } do
      repo = repository_fixture(owner, %{is_public: true})

      conn =
        conn
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> patch(~p"/api/v1/repos/#{repo.slug}", %{"name" => "New"})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "a non-owner on a public repository is 403, on a private one 404", %{
      conn: conn,
      owner: owner
    } do
      stranger = user_fixture()
      public = repository_fixture(owner, %{is_public: true})
      private = repository_fixture(owner, %{is_public: false})

      forbidden =
        conn
        |> bearer(session_token_for(stranger))
        |> patch(~p"/api/v1/repos/#{public.slug}", %{"name" => "New"})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      masked =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(session_token_for(stranger))
        |> patch(~p"/api/v1/repos/#{private.slug}", %{"name" => "New"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(masked, 404)
    end

    test "admins update any repository", %{conn: conn, owner: owner} do
      admin = admin_fixture()
      repo = repository_fixture(owner, %{is_public: false})

      conn =
        conn
        |> bearer(session_token_for(admin))
        |> patch(~p"/api/v1/repos/#{repo.slug}", %{"name" => "Admin"})

      assert json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/repos/:slug" do
    test "owners delete with 204", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner)

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}")

      assert response(conn, 204) == ""
      refute DarkZenith.Repositories.get_repository_by_slug(repo.slug)
    end

    test "API keys need repo:delete", %{conn: conn, owner: owner} do
      repo = repository_fixture(owner, %{is_public: true})

      conn =
        conn
        |> bearer(api_key_for(owner, ["repo:update"]))
        |> delete(~p"/api/v1/repos/#{repo.slug}")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end
  end
end
