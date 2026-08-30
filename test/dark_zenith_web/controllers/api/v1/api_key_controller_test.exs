defmodule DarkZenithWeb.Api.V1.ApiKeyControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    {plaintext, _} = Accounts.create_session_token(user)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> plaintext)

    %{conn: conn, user: user}
  end

  describe "POST /api/v1/api_keys" do
    test "creates a key and returns the plaintext exactly once", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/api_keys", %{
          "name" => "CI read-only",
          "scopes" => ["repo:read"]
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert %{"key" => "dzak_" <> _, "key_prefix" => "dzak_" <> _} = data
      assert data["scopes"] == ["repo:read"]
      assert data["is_expired"] == false
      assert data["expires_at"] == nil
    end

    test "accepts a future ISO-8601 UTC expires_at", %{conn: conn} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      conn =
        post(conn, ~p"/api/v1/api_keys", %{
          "name" => "expiring",
          "scopes" => ["repo:read"],
          "expires_at" => future
        })

      assert %{"data" => %{"expires_at" => expires_at}} = json_response(conn, 201)
      assert String.ends_with?(expires_at, "Z")
    end

    test "rejects a past expires_at and a malformed one", %{conn: conn} do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn
               |> post(~p"/api/v1/api_keys", %{
                 "name" => "k",
                 "scopes" => ["repo:read"],
                 "expires_at" => past
               })
               |> json_response(422)

      [auth] = get_req_header(conn, "authorization")

      assert %{"error" => %{"code" => "validation_failed"}} =
               build_conn()
               |> put_req_header("content-type", "application/json")
               |> put_req_header("authorization", auth)
               |> post(~p"/api/v1/api_keys", %{
                 "name" => "k",
                 "scopes" => ["repo:read"],
                 "expires_at" => "not-a-date"
               })
               |> json_response(422)
    end

    test "rejects API-key credentials with 403", %{user: user} do
      {:ok, {key, _}} = Accounts.create_api_key(user, %{name: "k", scopes: ["repo:read"]})

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/api/v1/api_keys", %{"name" => "x", "scopes" => ["repo:read"]})

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "requires authentication" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/api_keys", %{"name" => "x", "scopes" => ["repo:read"]})

      assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    end
  end

  describe "GET /api/v1/api_keys" do
    test "lists the user's keys in the paginated envelope", %{conn: conn, user: user} do
      {:ok, _} = Accounts.create_api_key(user, %{name: "one", scopes: ["repo:read"]})

      conn = get(conn, ~p"/api/v1/api_keys")

      assert %{"data" => [key], "pagination" => %{"total" => "1"}} = json_response(conn, 200)
      assert key["name"] == "one"
      refute Map.has_key?(key, "key")
      refute Map.has_key?(key, "key_hash")
    end
  end

  describe "DELETE /api/v1/api_keys/:id" do
    test "revokes the user's key", %{conn: conn, user: user} do
      {:ok, {_, key}} = Accounts.create_api_key(user, %{name: "gone", scopes: ["repo:read"]})

      conn = delete(conn, ~p"/api/v1/api_keys/#{key.id}")
      assert response(conn, 204) == ""
      assert Accounts.list_api_keys(user) == []
    end

    test "another user's key id is 404", %{conn: conn} do
      other = user_fixture()
      {:ok, {_, key}} = Accounts.create_api_key(other, %{name: "safe", scopes: ["repo:read"]})

      conn = delete(conn, ~p"/api/v1/api_keys/#{key.id}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
      assert [_] = Accounts.list_api_keys(other)
    end

    test "a malformed id is 404", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/api_keys/not-a-uuid")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end
end
