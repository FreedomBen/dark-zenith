defmodule DarkZenithWeb.ResponseHeadersTest do
  @moduledoc """
  Cross-surface response headers (DESIGN.md: Caching headers; Security
  Considerations): `Cache-Control: no-store` on web UI and `/api/v1`
  responses, `X-Content-Type-Options: nosniff` everywhere, and
  `Vary: Authorization, Cookie` on every repository-serving response,
  including rate-limited ones.
  """

  # Not async: the rate-limit override and its loopback IP identity are
  # process-global.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  setup do
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)
    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)
    :ets.delete_all_objects(DarkZenith.RateLimit)
    %{previous: previous}
  end

  test "web UI responses send Cache-Control: no-store and nosniff" do
    conn = get(build_conn(), ~p"/")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "api responses send Cache-Control: no-store and nosniff" do
    conn = get(build_conn(), ~p"/api/v1/repos")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "api error responses keep no-store and nosniff" do
    conn = get(build_conn(), ~p"/api/v1/api_keys")

    assert conn.status == 401
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "repository-serving responses send nosniff and keep their caching headers" do
    owner = user_fixture()
    repository = repository_fixture(owner, %{is_public: true})

    conn = get(build_conn(), "/repos/#{repository.slug}/repodata/repomd.xml")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "vary") == ["Authorization, Cookie"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=0, must-revalidate"]
  end

  test "repository-serving errors send nosniff and Vary" do
    conn = get(build_conn(), "/repos/no-such-repo/repodata/repomd.xml")

    assert conn.status == 401
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "vary") == ["Authorization, Cookie"]
  end

  test "rate-limited repository-serving responses send Vary and nosniff", ctx do
    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.merge(ctx.previous, %{general_unauth: {1, 60}})
    )

    owner = user_fixture()
    repository = repository_fixture(owner, %{is_public: true})
    path = "/repos/#{repository.slug}/repodata/repomd.xml"

    assert get(build_conn(), path).status == 200

    rejected = get(build_conn(), path)
    assert rejected.status == 429
    assert get_resp_header(rejected, "vary") == ["Authorization, Cookie"]
    assert get_resp_header(rejected, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(rejected, "cache-control") == ["no-store"]
  end
end
