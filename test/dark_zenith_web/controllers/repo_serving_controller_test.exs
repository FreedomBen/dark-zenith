defmodule DarkZenithWeb.RepoServingControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import Ecto.Query

  alias DarkZenith.Accounts
  alias DarkZenith.Repositories.Repository

  setup do
    owner = user_fixture()
    public_repo = repository_fixture(owner, %{slug: unique_slug(), is_public: true})
    private_repo = repository_fixture(owner, %{slug: unique_slug(), is_public: false})
    %{owner: owner, public_repo: public_repo, private_repo: private_repo}
  end

  defp basic_auth_header(conn, password) do
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("token:" <> password))
  end

  defp api_key_for(user, scopes \\ ["repo:read"]) do
    {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "test", scopes: scopes})
    plaintext
  end

  describe "public repodata" do
    test "serves repomd.xml with correct type, caching, and ETag", %{
      conn: conn,
      public_repo: repo
    } do
      conn = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 200) =~ "<revision>0</revision>"
      assert response_content_type(conn, :xml) =~ "application/xml"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=0, must-revalidate"]

      expected_etag =
        ~s(") <> Base.encode16(:crypto.hash(:sha256, conn.resp_body), case: :lower) <> ~s(")

      assert get_resp_header(conn, "etag") == [expected_etag]
      assert get_resp_header(conn, "vary") == ["Authorization, Cookie"]
      refute get_resp_header(conn, "last-modified") != []
    end

    test "serves the gzip artifacts with application/gzip", %{conn: conn, public_repo: repo} do
      for file <- ["primary.xml.gz", "filelists.xml.gz", "other.xml.gz"] do
        conn = get(build_conn(), "/repos/#{repo.slug}/repodata/#{file}")
        assert conn.status == 200
        assert response_content_type(conn, :gzip) =~ "application/gzip"
        assert :zlib.gunzip(conn.resp_body) =~ ~s(packages="0")
        _ = conn
      end

      _ = conn
    end

    test "returns 304 with an empty body for a matching If-None-Match", %{
      conn: conn,
      public_repo: repo
    } do
      first = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml")
      [etag] = get_resp_header(first, "etag")

      second =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert second.status == 304
      assert second.resp_body == ""
    end

    test "ignores If-Modified-Since entirely", %{conn: conn, public_repo: repo} do
      conn =
        conn
        |> put_req_header("if-modified-since", "Thu, 01 Jan 2099 00:00:00 GMT")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "ignores query strings", %{conn: conn, public_repo: repo} do
      conn = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml?cachebust=1&x=y")
      assert conn.status == 200
    end

    test "supports HEAD with the same status and headers", %{conn: conn, public_repo: repo} do
      conn = head(conn, "/repos/#{repo.slug}/repodata/repomd.xml")
      assert conn.status == 200
      assert [_] = get_resp_header(conn, "etag")
    end

    test "unknown repodata filenames are plain-text 404", %{conn: conn, public_repo: repo} do
      conn = get(conn, "/repos/#{repo.slug}/repodata/evil.xml")
      assert response(conn, 404) == "not_found"
      assert response_content_type(conn, :text) =~ "text/plain"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "repomd.xml.asc is 404 when no signing key is configured", %{
      conn: conn,
      public_repo: repo
    } do
      conn = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml.asc")
      assert response(conn, 404) == "not_found"
    end
  end

  describe "metadata_not_ready" do
    test "a stale cache returns plain-text 503 with Retry-After 5", %{
      conn: conn,
      public_repo: repo
    } do
      # Bump the repository revision past the cache's source_revision.
      {1, _} =
        DarkZenith.Repo.update_all(
          from(r in Repository, where: r.id == ^repo.id),
          set: [metadata_revision: 1]
        )

      conn = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 503) == "metadata_not_ready"
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "anonymous requests to private or unknown slugs" do
    test "receive the Basic challenge without leaking existence", %{
      conn: conn,
      private_repo: repo
    } do
      private = get(conn, "/repos/#{repo.slug}/repodata/repomd.xml")
      missing = get(build_conn(), "/repos/does-not-exist/repodata/repomd.xml")

      for response_conn <- [private, missing] do
        assert response(response_conn, 401) == "unauthenticated"

        assert get_resp_header(response_conn, "www-authenticate") == [
                 ~s(Basic realm="Dark Zenith")
               ]
      end
    end
  end

  describe "credentialed requests to private repositories" do
    test "the owner's repo:read API key works via Basic auth", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      key = api_key_for(owner)

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 200) =~ "<revision>"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      # Private responses still carry the strong ETag and honor If-None-Match.
      [etag] = get_resp_header(conn, "etag")

      cached =
        build_conn()
        |> basic_auth_header(key)
        |> put_req_header("if-none-match", etag)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert cached.status == 304
    end

    test "the same key works as a Bearer credential", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      key = api_key_for(owner)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "a session token authorizes as its user", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      {plaintext, _} = Accounts.create_session_token(owner)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "a browser session cookie authorizes as its user", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      conn =
        conn
        |> log_in_user(owner)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "admins can read any private repository", %{conn: conn, private_repo: repo} do
      admin = admin_fixture()
      key = api_key_for(admin)

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "a valid key without repo:read is masked as 404", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      key = api_key_for(owner, ["package:upload"])

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end

    test "a valid principal without repository access is masked as 404", %{
      conn: conn,
      private_repo: repo
    } do
      stranger = user_fixture()
      key = api_key_for(stranger)

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end

    test "a collaborator's repo:read key can read the private repository", %{
      conn: conn,
      private_repo: repo
    } do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(repo, collaborator)
      key = api_key_for(collaborator)

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "a collaborator's key without repo:read is still masked as 404", %{
      conn: conn,
      private_repo: repo
    } do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(repo, collaborator)
      key = api_key_for(collaborator, ["package:upload"])

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end

    test "a collaborator's browser session cookie can read the private repository", %{
      conn: conn,
      private_repo: repo
    } do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(repo, collaborator)

      conn =
        conn
        |> log_in_user(collaborator)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "invalid credentials are masked as 404 on private slugs", %{
      conn: conn,
      private_repo: repo
    } do
      conn =
        conn
        |> basic_auth_header("dzak_invalid")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end

    test "an unsupported authorization scheme never falls back", %{
      conn: conn,
      private_repo: repo
    } do
      conn =
        conn
        |> put_req_header("authorization", "Digest whatever")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end

    test "a stale session cookie with no header is masked as 404", %{
      conn: conn,
      private_repo: repo
    } do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, "stale-token")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 404) == "not_found"
    end
  end

  describe "credentialed requests to public repositories" do
    test "valid optional credentials are accepted", %{conn: conn, public_repo: repo} do
      user = user_fixture()
      key = api_key_for(user, ["package:delete"])

      conn =
        conn
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end

    test "invalid presented credentials return the 401 challenge instead of anonymous access",
         %{conn: conn, public_repo: repo} do
      conn =
        conn
        |> basic_auth_header("dzak_wrong")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert response(conn, 401) == "unauthenticated"
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Dark Zenith")]
    end

    test "a stale session cookie with no header proceeds anonymously", %{
      conn: conn,
      public_repo: repo
    } do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, "stale-token")
        |> get("/repos/#{repo.slug}/repodata/repomd.xml")

      assert conn.status == 200
    end
  end

  describe "RPM-GPG-KEY" do
    test "is 404 when the repository has no configured key", %{conn: conn, public_repo: repo} do
      conn = get(conn, "/repos/#{repo.slug}/RPM-GPG-KEY")
      assert response(conn, 404) == "not_found"
    end

    test "serves the owner's public key as text/plain when configured", %{
      conn: conn,
      owner: owner,
      public_repo: repo
    } do
      put_user_gpg_fingerprint(owner)

      # Configure the repository fingerprint directly (the validated update
      # path requires the signing machinery).
      {1, _} =
        DarkZenith.Repo.update_all(
          from(r in Repository, where: r.id == ^repo.id),
          set: [gpg_key_fingerprint: String.duplicate("A", 40)]
        )

      conn = get(conn, "/repos/#{repo.slug}/RPM-GPG-KEY")

      assert response(conn, 200) =~ "BEGIN PGP PUBLIC KEY BLOCK"
      assert response_content_type(conn, :text) =~ "text/plain"
    end
  end

  describe "dark-zenith.repo" do
    test "renders the public unsigned configuration", %{conn: conn, public_repo: repo} do
      conn = get(conn, "/repos/#{repo.slug}/dark-zenith.repo")
      body = response(conn, 200)

      assert body =~ "[dark-zenith-#{repo.slug}]"
      assert body =~ "name=Dark Zenith - #{repo.name}"
      assert body =~ "baseurl=#{DarkZenithWeb.Endpoint.url()}/repos/#{repo.slug}/"
      assert body =~ "enabled=1"
      assert body =~ "metadata_expire=6h"
      assert body =~ "repo_gpgcheck=0"
      assert body =~ "gpgcheck=0"
      refute body =~ "gpgkey="
      refute body =~ "password"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="dark-zenith-#{repo.slug}.repo")
             ]

      assert get_resp_header(conn, "cache-control") == ["public, max-age=0, must-revalidate"]
    end

    test "private repositories require read access and embed placeholders", %{
      conn: conn,
      owner: owner,
      private_repo: repo
    } do
      anonymous = get(conn, "/repos/#{repo.slug}/dark-zenith.repo")
      assert response(anonymous, 401) == "unauthenticated"

      key = api_key_for(owner)

      conn =
        build_conn()
        |> basic_auth_header(key)
        |> get("/repos/#{repo.slug}/dark-zenith.repo")

      body = response(conn, 200)
      assert body =~ "username=token"
      assert body =~ "password=<api-key>"
      refute body =~ key
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "includes the gpgkey line when a fingerprint is configured", %{
      conn: conn,
      public_repo: repo
    } do
      {1, _} =
        DarkZenith.Repo.update_all(
          from(r in Repository, where: r.id == ^repo.id),
          set: [gpg_key_fingerprint: String.duplicate("A", 40)]
        )

      conn = get(conn, "/repos/#{repo.slug}/dark-zenith.repo")
      body = response(conn, 200)

      assert body =~ "repo_gpgcheck=1"
      assert body =~ "gpgkey=#{DarkZenithWeb.Endpoint.url()}/repos/#{repo.slug}/RPM-GPG-KEY"
    end
  end
end
