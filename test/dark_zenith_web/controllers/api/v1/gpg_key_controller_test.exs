defmodule DarkZenithWeb.Api.V1.GpgKeyControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    {plaintext, _} = Accounts.create_session_token(user)
    %{conn: conn, user: user, token: plaintext}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp put_multipart(conn, params) do
    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=test")
    |> put(~p"/api/v1/gpg_key", params)
  end

  test "the full upload, read, and remove lifecycle", ctx do
    pair = generate_key_pair()

    uploaded =
      ctx.conn
      |> bearer(ctx.token)
      |> put_multipart(%{"public_key" => pair.public, "private_key" => pair.private})

    assert %{"data" => data} = json_response(uploaded, 200)
    assert data["fingerprint"] == pair.fingerprint
    assert data["signing_fingerprint"] == pair.fingerprint
    assert data["expires_at"] == nil
    assert data["public_key"] =~ "BEGIN PGP PUBLIC KEY"
    assert data["replacement_in_progress"] == false
    refute Map.has_key?(data, "private_key")

    read = build_conn() |> bearer(ctx.token) |> get(~p"/api/v1/gpg_key")
    assert %{"data" => %{"fingerprint" => fingerprint}} = json_response(read, 200)
    assert fingerprint == pair.fingerprint

    removed = build_conn() |> bearer(ctx.token) |> delete(~p"/api/v1/gpg_key")
    assert response(removed, 204) == ""

    gone = build_conn() |> bearer(ctx.token) |> get(~p"/api/v1/gpg_key")
    assert %{"error" => %{"code" => "not_found"}} = json_response(gone, 404)
  end

  test "an in-use key returns 409 on delete", ctx do
    pair = generate_key_pair()
    {:ok, user} = Accounts.upsert_gpg_key(ctx.user, pair.public, pair.private)

    {:ok, _repo} =
      DarkZenith.Repositories.create_repository(user, %{
        slug: "gpg-in-use-#{System.unique_integer([:positive])}",
        name: "K",
        gpg_key_fingerprint: pair.fingerprint
      })

    conn = ctx.conn |> bearer(ctx.token) |> delete(~p"/api/v1/gpg_key")
    assert %{"error" => %{"code" => "conflict_gpg_key_in_use"}} = json_response(conn, 409)
  end

  test "rejects invalid armor with validation_failed", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_multipart(%{"public_key" => "junk", "private_key" => "junk"})

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "rejects unknown multipart fields and non-multipart bodies", ctx do
    unknown =
      ctx.conn
      |> bearer(ctx.token)
      |> put_multipart(%{"public_key" => "x", "private_key" => "y", "extra" => "z"})

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(unknown, 422)

    json_body =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> bearer(ctx.token)
      |> put(~p"/api/v1/gpg_key", %{"public_key" => "x", "private_key" => "y"})

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(json_body, 400)
  end

  test "API keys cannot manage GPG keys", ctx do
    {:ok, {key, _}} = Accounts.create_api_key(ctx.user, %{name: "k", scopes: ["repo:read"]})

    conn = ctx.conn |> bearer(key) |> get(~p"/api/v1/gpg_key")
    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
  end

  test "requires authentication", ctx do
    conn = get(ctx.conn, ~p"/api/v1/gpg_key")
    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
  end
end
