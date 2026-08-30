defmodule DarkZenithWeb.Api.V1.AuthControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "content-type", "application/json"), user: user_fixture()}
  end

  describe "POST /api/v1/auth/login" do
    test "returns a session token with expiry", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert %{"data" => %{"token" => "dzst_" <> _ = token, "expires_at" => expires_at}} =
               json_response(conn, 200)

      assert {:ok, _dt, 0} = DateTime.from_iso8601(expires_at)
      assert String.ends_with?(expires_at, "Z")
      assert Accounts.get_user_by_api_session_token(token).id == user.id
    end

    test "returns 401 with no detail for wrong password", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{"email" => user.email, "password" => "wrong!"})

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "returns the same 401 for an unknown email", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "email" => "nobody@example.com",
          "password" => "hello world password!"
        })

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "returns the same 401 for an unconfirmed account", %{conn: conn} do
      unconfirmed = unconfirmed_user_fixture()

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "email" => unconfirmed.email,
          "password" => valid_user_password()
        })

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "rejects unknown JSON fields", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "email" => user.email,
          "password" => valid_user_password(),
          "surprise" => true
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "rejects query parameters on a route that documents none", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/login?extra=1", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "rejects missing fields", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/login", %{"email" => "x@example.com"})
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end

    test "works without a CSRF token when no session cookie is present", %{
      conn: conn,
      user: user
    } do
      # ConnTest normally skips CSRF; disable the skip to exercise the real
      # pipeline behavior a curl client sees.
      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/api/v1/auth/login", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert %{"data" => %{"token" => "dzst_" <> _}} = json_response(conn, 200)
    end

    test "cookie-authenticated mutations require a CSRF token", %{user: user} do
      conn = log_in_user(build_conn(), user)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/api_keys", %{"name" => "x", "scopes" => ["repo:read"]})
      end
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    test "invalidates the presented session token", %{conn: conn, user: user} do
      {plaintext, _} = Accounts.create_session_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> delete(~p"/api/v1/auth/logout")

      assert response(conn, 204) == ""
      refute Accounts.get_user_by_api_session_token(plaintext)
    end

    test "rejects API-key authentication with 403", %{conn: conn, user: user} do
      {:ok, {key, _}} = Accounts.create_api_key(user, %{name: "k", scopes: ["repo:read"]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> delete(~p"/api/v1/auth/logout")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "rejects session-cookie authentication with 403", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> delete(~p"/api/v1/auth/logout")

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "requires authentication", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/auth/logout")
      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end

    test "rejects an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer dzst_bogus")
        |> delete(~p"/api/v1/auth/logout")

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end
  end
end
