defmodule DarkZenithWeb.Plugs.RateLimiterTest do
  # Not async: tightens the global rate-limit overrides and shares one
  # loopback IP identity across requests.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts

  setup do
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)
    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)
    :ets.delete_all_objects(DarkZenith.RateLimit)
    %{previous: previous}
  end

  defp override!(previous, changes) do
    Application.put_env(:dark_zenith, :rate_limit_overrides, Map.merge(previous, changes))
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "authenticated API requests use the per-user general bucket", ctx do
    override!(ctx.previous, %{general_auth: {2, 60}})
    user = user_fixture()
    {token, _} = Accounts.create_session_token(user)

    first = build_conn() |> bearer(token) |> get(~p"/api/v1/repos")
    assert first.status == 200
    assert get_resp_header(first, "x-ratelimit-limit") == ["2"]
    assert get_resp_header(first, "x-ratelimit-remaining") == ["1"]

    # The last slot is admitted with zero remaining.
    second = build_conn() |> bearer(token) |> get(~p"/api/v1/repos")
    assert second.status == 200
    assert get_resp_header(second, "x-ratelimit-remaining") == ["0"]

    third = build_conn() |> bearer(token) |> get(~p"/api/v1/repos")
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(third, 429)
    assert [retry_after] = get_resp_header(third, "retry-after")
    assert String.to_integer(retry_after) >= 1

    # Another user is unaffected.
    other = user_fixture()
    {other_token, _} = Accounts.create_session_token(other)
    ok = build_conn() |> bearer(other_token) |> get(~p"/api/v1/repos")
    assert ok.status == 200
  end

  test "unauthenticated requests share the per-IP bucket and get the upsell", ctx do
    override!(ctx.previous, %{general_unauth: {1, 60}})

    assert get(build_conn(), ~p"/api/v1/repos").status == 200

    rejected = get(build_conn(), ~p"/api/v1/repos")
    assert %{"error" => %{"message" => message}} = json_response(rejected, 429)
    assert message =~ "authenticate for higher limits"
  end

  test "login uses the auth-attempt buckets in lieu of the general bucket", ctx do
    override!(ctx.previous, %{
      general_unauth: {1, 60},
      auth_attempt_ip: {10, 60},
      auth_attempt_email: {2, 60}
    })

    login = fn email ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/auth/login", %{"email" => email, "password" => "wrong password!"})
    end

    # Three logins pass the (exhausted) general bucket because auth-attempt
    # buckets replace it; the third same-email hit trips the email bucket.
    assert login.("target@example.com").status == 401
    assert login.("target@example.com").status == 401
    third = login.("target@example.com")
    assert third.status == 429

    # A different email still has room; the shared IP bucket allows it.
    assert login.("other@example.com").status == 401

    # Invalid emails consume only the IP bucket and cannot mint buckets.
    assert login.("not-an-email").status in [401, 422]
  end

  test "package downloads use their own in-lieu bucket", ctx do
    override!(ctx.previous, %{general_unauth: {1, 60}, download_unauth: {2, 60}})

    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: true})

    package =
      DarkZenith.PackagesFixtures.insert_package_from_rpm!(
        repo,
        DarkZenith.RpmFixtures.minimal_binary()
      )

    path = "/repos/#{repo.slug}/packages/#{package.id}/dz-minimal-0.1-1.noarch.rpm"

    # Two downloads pass even though the general unauth bucket allows one.
    assert get(build_conn(), path).status == 302
    assert get(build_conn(), path).status == 302

    rejected = get(build_conn(), path)
    assert rejected.status == 429
    assert response(rejected, 429) == "rate_limited"
    assert get_resp_header(rejected, "content-type") |> hd() =~ "text/plain"
  end

  test "specialized buckets compose with the general bucket", ctx do
    override!(ctx.previous, %{general_auth: {100, 60}, api_key_create: {1, 3600}})

    user = user_fixture()
    {token, _} = Accounts.create_session_token(user)

    create = fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> bearer(token)
      |> post(~p"/api/v1/api_keys", %{
        "name" => "k#{System.unique_integer([:positive])}",
        "scopes" => ["repo:read"]
      })
    end

    assert create.().status == 201
    assert create.().status == 429

    # General requests still flow: the hourly bucket composed, not replaced.
    assert build_conn() |> bearer(token) |> get(~p"/api/v1/repos") |> Map.fetch!(:status) == 200
  end

  test "GPG key generation consumes the gpg_key_mutation bucket", ctx do
    override!(ctx.previous, %{general_auth: {100, 60}, gpg_key_mutation: {1, 3600}})

    user = user_fixture()
    {token, _} = Accounts.create_session_token(user)

    first = build_conn() |> bearer(token) |> post(~p"/api/v1/gpg_key/generation")
    assert first.status == 200

    second = build_conn() |> bearer(token) |> post(~p"/api/v1/gpg_key/generation")
    assert second.status == 429

    # General requests still flow: the hourly bucket composed, not replaced.
    assert build_conn() |> bearer(token) |> get(~p"/api/v1/repos") |> Map.fetch!(:status) == 200
  end

  test "browser requests render an HTML 429", ctx do
    override!(ctx.previous, %{general_unauth: {1, 60}})

    assert get(build_conn(), ~p"/").status == 200

    rejected = get(build_conn(), ~p"/")
    assert rejected.status == 429
    assert response(rejected, 429) =~ "Sign in for higher rate limits"
  end
end
