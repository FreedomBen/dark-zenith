defmodule DarkZenithWeb.Api.V1.CollaboratorControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Collaborators

  setup %{conn: conn} do
    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: false})

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      owner: owner,
      repo: repo
    }
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

  describe "GET /api/v1/repos/:slug/collaborators" do
    test "lists typed rows in the pagination envelope, sorted by email", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      collab_user = user_fixture(%{email: "mmm#{System.unique_integer([:positive])}@example.com"})
      {:ok, :created, _} = Collaborators.add_collaborator(owner, repo, collab_user.email)

      a_email = "aaa#{System.unique_integer([:positive])}@example.com"
      {:ok, :created, _} = Collaborators.add_collaborator(owner, repo, a_email)

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert %{"data" => [first, second], "pagination" => pagination} = json_response(conn, 200)
      assert %{"type" => "invitation", "email" => ^a_email, "invited_by_id" => invited_by} = first
      assert invited_by == owner.id
      assert first["notification_generation"] == "1"
      assert first["notification_status"] == "queued"
      assert is_binary(first["expires_at"])

      assert %{"type" => "collaborator", "user_id" => user_id} = second
      assert user_id == collab_user.id
      assert second["email"] == collab_user.email
      assert second["notification_generation"] == "1"
      assert is_nil(second["notification_sent_at"])

      assert pagination["total"] == "2"
      assert pagination["total_pages"] == "1"
      assert pagination["page"] == 1
    end

    test "paginates the merged listing", %{conn: conn, owner: owner, repo: repo} do
      for _ <- 1..3 do
        {:ok, :created, _} = Collaborators.add_collaborator(owner, repo, unique_invited_email())
      end

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators?page=2&per_page=2")

      assert %{"data" => data, "pagination" => pagination} = json_response(conn, 200)
      assert length(data) == 1
      assert pagination["total"] == "3"
      assert pagination["total_pages"] == "2"
      assert pagination["page"] == 2
    end

    test "requires repo:read on API keys", %{conn: conn, owner: owner, repo: repo} do
      ok =
        conn
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert json_response(ok, 200)

      missing_scope =
        build_conn()
        |> bearer(api_key_for(owner, ["repo:update"]))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(missing_scope, 403)
    end

    test "collaborators themselves get 403; strangers get the masked 404", %{
      conn: conn,
      owner: _owner,
      repo: repo
    } do
      collaborator = user_fixture()
      collaborator_row_fixture(repo, collaborator)

      as_collaborator =
        conn
        |> bearer(session_token_for(collaborator))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(as_collaborator, 403)

      stranger =
        build_conn()
        |> bearer(session_token_for(user_fixture()))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert %{"error" => %{"code" => "not_found"}} = json_response(stranger, 404)
    end

    test "anonymous requests get 404 on private and 401 on public repositories", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      private = get(conn, ~p"/api/v1/repos/#{repo.slug}/collaborators")
      assert %{"error" => %{"code" => "not_found"}} = json_response(private, 404)

      public_repo = repository_fixture(owner, %{is_public: true})
      public = get(build_conn(), ~p"/api/v1/repos/#{public_repo.slug}/collaborators")
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(public, 401)
    end

    test "admins can list any repository's collaborators", %{conn: conn, repo: repo} do
      admin = admin_fixture()

      conn =
        conn
        |> bearer(session_token_for(admin))
        |> get(~p"/api/v1/repos/#{repo.slug}/collaborators")

      assert json_response(conn, 200)
    end
  end

  describe "POST /api/v1/repos/:slug/collaborators" do
    test "creates an invitation with 201 and returns it idempotently with 200", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      email = unique_invited_email()

      created =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{"email" => email})

      assert %{"data" => %{"type" => "invitation", "email" => ^email}} =
               json_response(created, 201)

      existing =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{"email" => email})

      assert %{"data" => %{"type" => "invitation", "email" => ^email}} =
               json_response(existing, 200)
    end

    test "creates a collaborator row for a registered email", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      user = user_fixture()

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{"email" => user.email})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["type"] == "collaborator"
      assert data["user_id"] == user.id
      assert data["email"] == user.email
      assert data["notification_generation"] == "1"
    end

    test "rejects the owner's email and public repositories with 422", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      own =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{"email" => owner.email})

      assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
               json_response(own, 422)

      assert %{"email" => [_]} = details

      public_repo = repository_fixture(owner, %{is_public: true})

      public =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{public_repo.slug}/collaborators", %{
          "email" => unique_invited_email()
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(public, 422)
    end

    test "a repo:read key that can read the repo still gets 403 on add", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      conn =
        conn
        |> bearer(api_key_for(owner, ["repo:read"]))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{
          "email" => unique_invited_email()
        })

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "rejects unknown body fields and missing email", %{conn: conn, owner: owner, repo: repo} do
      unknown =
        conn
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{
          "email" => unique_invited_email(),
          "extra" => 1
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(unknown, 422)

      missing =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(session_token_for(owner))
        |> post(~p"/api/v1/repos/#{repo.slug}/collaborators", %{})

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(missing, 422)
    end
  end

  describe "DELETE endpoints" do
    test "removes a collaborator and cancels an invitation with 204", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      user = user_fixture()
      {:ok, :created, collaborator} = Collaborators.add_collaborator(owner, repo, user.email)

      {:ok, :created, invitation} =
        Collaborators.add_collaborator(owner, repo, unique_invited_email())

      removed =
        conn
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/collaborators/#{collaborator.id}")

      assert response(removed, 204) == ""

      canceled =
        build_conn()
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/collaborators/invitations/#{invitation.id}")

      assert response(canceled, 204) == ""
    end

    test "ids under another repository and malformed ids are 404", %{
      conn: conn,
      owner: owner,
      repo: repo
    } do
      other_repo = repository_fixture(owner, %{is_public: false})
      user = user_fixture()

      {:ok, :created, collaborator} =
        Collaborators.add_collaborator(owner, other_repo, user.email)

      cross =
        conn
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/collaborators/#{collaborator.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(cross, 404)

      malformed =
        build_conn()
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/collaborators/not-a-uuid")

      assert %{"error" => %{"code" => "not_found"}} = json_response(malformed, 404)
    end

    test "removal works while the repository is public", %{conn: conn, owner: owner, repo: repo} do
      user = user_fixture()
      {:ok, :created, collaborator} = Collaborators.add_collaborator(owner, repo, user.email)

      {:ok, _} = DarkZenith.Repositories.update_repository(owner, repo, %{"is_public" => true})

      conn =
        conn
        |> bearer(session_token_for(owner))
        |> delete(~p"/api/v1/repos/#{repo.slug}/collaborators/#{collaborator.id}")

      assert response(conn, 204) == ""
    end
  end
end
