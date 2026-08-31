defmodule DarkZenithWeb.AuditContextTest do
  @moduledoc """
  Client IP on audit events (DESIGN.md: Audit Events `ip`): user-initiated
  actions on the API and web surfaces — including actions audited inside
  context functions — record the IP resolved by the client IP detection
  rules; system events stay null.
  """

  # Not async: one test overrides the trusted-proxies configuration.
  use DarkZenithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenith.ClientIp

  defp events(action) do
    Enum.filter(Audit.list_events(), &(&1.action == action))
  end

  describe "ClientIp.resolve_peer/2" do
    test "walks a trusted peer's forwarded chain and ignores an untrusted one" do
      previous = Application.get_env(:dark_zenith, :trusted_proxies)
      on_exit(fn -> Application.put_env(:dark_zenith, :trusted_proxies, previous) end)

      headers = [{"x-forwarded-for", "203.0.113.5, 10.0.0.1"}]

      Application.put_env(:dark_zenith, :trusted_proxies, [
        {{127, 0, 0, 1}, 32},
        {{10, 0, 0, 1}, 32}
      ])

      assert ClientIp.resolve_peer({127, 0, 0, 1}, headers) == {203, 0, 113, 5}

      Application.put_env(:dark_zenith, :trusted_proxies, [])
      assert ClientIp.resolve_peer({127, 0, 0, 1}, headers) == {127, 0, 0, 1}
    end
  end

  describe "API surface" do
    test "repository creation records the client IP" do
      user = user_fixture()
      {token, _} = Accounts.create_session_token(user)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/v1/repos", %{"name" => "Audited", "slug" => "audited-ip"})

      assert conn.status == 201
      assert [event] = events("repository.create")
      assert event.ip == "127.0.0.1"
      assert event.actor_id == user.id
    end

    test "api key creation and revocation audit once, in the transaction, with the IP" do
      user = user_fixture()
      {token, _} = Accounts.create_session_token(user)

      created =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/v1/api_keys", %{"name" => "k", "scopes" => ["repo:read"]})

      assert %{"data" => %{"id" => key_id}} = json_response(created, 201)
      assert [create_event] = events("api_key.create")
      assert create_event.ip == "127.0.0.1"
      assert create_event.target_id == key_id

      deleted =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> delete(~p"/api/v1/api_keys/#{key_id}")

      assert deleted.status == 204
      assert [revoke_event] = events("api_key.revoke")
      assert revoke_event.ip == "127.0.0.1"
    end

    test "login and failed login record the client IP" do
      user = user_fixture()

      ok =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/auth/login", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert ok.status == 200

      failed =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/auth/login", %{"email" => user.email, "password" => "wrong password"})

      assert failed.status == 401

      assert [login] = events("auth.login")
      assert login.ip == "127.0.0.1"
      assert login.metadata["surface"] == "api"

      assert [login_failed] = events("auth.login_failed")
      assert login_failed.ip == "127.0.0.1"
    end
  end

  describe "web surface" do
    test "web login success and failure are audited with the client IP" do
      user = user_fixture()

      ok =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(ok)

      failed =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong password"}
        })

      assert redirected_to(failed) == ~p"/users/log-in"

      assert [login] = events("auth.login")
      assert login.ip == "127.0.0.1"
      assert login.metadata["surface"] == "web"
      assert login.actor_id == user.id

      assert [login_failed] = events("auth.login_failed")
      assert login_failed.ip == "127.0.0.1"
      assert login_failed.metadata["surface"] == "web"
    end

    test "LiveView-recorded actions carry the socket's client IP", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#create_api_key_form", api_key: %{"name" => "ip key", "scopes" => ["repo:read"]})
      |> render_submit()

      assert [event] = events("api_key.create")
      assert event.ip == "127.0.0.1"
      assert event.metadata["name"] == "ip key"
    end
  end
end
