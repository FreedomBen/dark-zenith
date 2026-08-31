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

  test "rejects a key field over 1 MiB with 413 payload_too_large", ctx do
    oversized = String.duplicate("a", 1_048_577)

    upload =
      ctx.conn
      |> bearer(ctx.token)
      |> put_multipart(%{"public_key" => oversized, "private_key" => "small"})

    assert %{"error" => %{"code" => "payload_too_large"}} = json_response(upload, 413)

    revocation =
      build_conn()
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> post(~p"/api/v1/gpg_key/revocation", %{
        "strategy" => "replace_key",
        "public_key" => "small",
        "private_key" => oversized
      })

    assert %{"error" => %{"code" => "payload_too_large"}} = json_response(revocation, 413)
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

    generated = build_conn() |> bearer(key) |> post(~p"/api/v1/gpg_key/generation")
    assert %{"error" => %{"code" => "forbidden"}} = json_response(generated, 403)
  end

  test "requires authentication", ctx do
    conn = get(ctx.conn, ~p"/api/v1/gpg_key")
    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)

    generated = post(build_conn(), ~p"/api/v1/gpg_key/generation")
    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(generated, 401)
  end

  describe "POST /api/v1/gpg_key/generation" do
    test "generates a first key and reveals the private key exactly once", ctx do
      conn = ctx.conn |> bearer(ctx.token) |> post(~p"/api/v1/gpg_key/generation")

      assert %{"data" => %{"gpg_key" => key, "private_key" => private}} =
               json_response(conn, 200)

      assert private =~ "BEGIN PGP PRIVATE KEY BLOCK"
      assert key["fingerprint"]
      assert key["signing_fingerprint"] == key["fingerprint"]
      assert key["expires_at"] == nil
      assert key["public_key"] =~ "BEGIN PGP PUBLIC KEY"
      refute Map.has_key?(key, "private_key")

      # Never retrievable again.
      read = build_conn() |> bearer(ctx.token) |> get(~p"/api/v1/gpg_key")
      assert %{"data" => read_data} = json_response(read, 200)
      refute inspect(read_data) =~ "PRIVATE KEY BLOCK"
    end

    test "accepts an explicit algorithm in a JSON body", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/gpg_key/generation", Jason.encode!(%{algorithm: "ed25519"}))

      assert %{"data" => %{"gpg_key" => _, "private_key" => _}} = json_response(conn, 200)
    end

    test "rejects unknown algorithms and unknown fields", ctx do
      bad_algorithm =
        ctx.conn
        |> bearer(ctx.token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/gpg_key/generation", Jason.encode!(%{algorithm: "rsa2048"}))

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(bad_algorithm, 422)

      unknown_field =
        build_conn()
        |> bearer(ctx.token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/gpg_key/generation", Jason.encode!(%{algo: "ed25519"}))

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(unknown_field, 422)

      assert Accounts.get_gpg_key_info(ctx.user) == nil
    end

    test "generating over an existing key returns 202 with the one-time private key", ctx do
      pair = generate_key_pair()
      {:ok, _} = Accounts.upsert_gpg_key(ctx.user, pair.public, pair.private)

      conn = ctx.conn |> bearer(ctx.token) |> post(~p"/api/v1/gpg_key/generation")

      assert %{"data" => %{"transition" => transition, "private_key" => private}} =
               json_response(conn, 202)

      assert get_resp_header(conn, "retry-after") == ["2"]
      assert transition["kind"] == "replace_gpg_key"
      assert transition["status"] == "preparing"
      assert private =~ "BEGIN PGP PRIVATE KEY BLOCK"

      # The retained transition resource never exposes the candidate.
      poll =
        build_conn()
        |> bearer(ctx.token)
        |> get(~p"/api/v1/gpg_key/transitions/#{transition["id"]}")

      refute inspect(json_response(poll, 200)) =~ "PRIVATE KEY"

      # A second generation is refused while the replacement is unresolved.
      again = build_conn() |> bearer(ctx.token) |> post(~p"/api/v1/gpg_key/generation")

      assert %{"error" => %{"code" => "conflict_gpg_key_transition_in_progress"}} =
               json_response(again, 409)
    end
  end
end

defmodule DarkZenithWeb.Api.V1.GpgKeyTransitionApiTest do
  # Not async: overrides the signing implementation.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Repositories

  setup %{conn: conn} do
    Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)
    on_exit(fn -> Application.delete_env(:dark_zenith, :signing_impl) end)

    pair = generate_key_pair()
    user = user_fixture()
    {:ok, user} = Accounts.upsert_gpg_key(user, pair.public, pair.private)

    {:ok, repo} =
      Repositories.create_repository(user, %{
        slug: "api-tr-#{System.unique_integer([:positive])}",
        name: "T",
        gpg_key_fingerprint: pair.fingerprint
      })

    {plaintext, _} = Accounts.create_session_token(user)
    %{conn: conn, user: user, token: plaintext, pair: pair, repo: repo}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "replacing an existing key returns 202 with the transition resource", ctx do
    pair2 = generate_key_pair()

    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> put(~p"/api/v1/gpg_key", %{
        "public_key" => pair2.public,
        "private_key" => pair2.private
      })

    assert %{"data" => data} = json_response(conn, 202)
    assert get_resp_header(conn, "retry-after") == ["2"]
    assert data["kind"] == "replace_gpg_key"
    assert data["status"] == "preparing"
    assert data["target_fingerprint"] == pair2.fingerprint
    assert data["repository_count"] == "0"
    assert data["item_count"] == "0"
    assert data["error"] == nil
    refute Map.has_key?(data, "prepared_gpg_key_private")

    # The key resource reports the replacement and links the transition.
    read = build_conn() |> bearer(ctx.token) |> get(~p"/api/v1/gpg_key")
    assert %{"data" => key} = json_response(read, 200)
    assert key["replacement_in_progress"] == true
    assert key["fingerprint"] == ctx.pair.fingerprint
    assert key["transition"]["id"] == data["id"]

    # Polling returns the resource with Retry-After while unresolved.
    poll = build_conn() |> bearer(ctx.token) |> get(~p"/api/v1/gpg_key/transitions/#{data["id"]}")
    assert %{"data" => polled} = json_response(poll, 200)
    assert get_resp_header(poll, "retry-after") == ["2"]
    assert polled["id"] == data["id"]

    # A second replacement is refused while unresolved.
    again =
      build_conn()
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> put(~p"/api/v1/gpg_key", %{
        "public_key" => pair2.public,
        "private_key" => pair2.private
      })

    assert %{"error" => %{"code" => "conflict_gpg_key_transition_in_progress"}} =
             json_response(again, 409)
  end

  test "delete of an in-use key carries repository counts", ctx do
    conn = ctx.conn |> bearer(ctx.token) |> delete(~p"/api/v1/gpg_key")

    assert %{"error" => %{"code" => "conflict_gpg_key_in_use", "details" => details}} =
             json_response(conn, 409)

    assert details["metadata_signed_repositories"] == "1"
    assert details["rpm_signed_repositories"] == "0"
  end

  test "revocation with clear_metadata_signing returns 202 and delete becomes fenced", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "clear_metadata_signing"})
      )

    assert %{"data" => data} = json_response(conn, 202)
    assert data["kind"] == "clear_metadata_signing"
    assert data["target_fingerprint"] == nil

    # An unresolved removal owns key deletion.
    blocked = build_conn() |> bearer(ctx.token) |> delete(~p"/api/v1/gpg_key")

    assert %{"error" => %{"code" => "conflict_gpg_key_transition_in_progress"}} =
             json_response(blocked, 409)
  end

  test "clear_metadata_signing conflicts when RPM signing is enabled", ctx do
    {:ok, _} =
      Repositories.create_repository(ctx.user, %{
        slug: "api-rpm-#{System.unique_integer([:positive])}",
        name: "R",
        gpg_key_fingerprint: ctx.pair.fingerprint,
        sign_rpms: true
      })

    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "clear_metadata_signing"})
      )

    assert %{"error" => %{"code" => "conflict_gpg_key_in_use"}} = json_response(conn, 409)
  end

  test "multipart revocation is accepted only with strategy=replace_key", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> post(~p"/api/v1/gpg_key/revocation", %{
        "strategy" => "clear_metadata_signing",
        "public_key" => "x"
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "multipart replace_key starts a replacement", ctx do
    pair2 = generate_key_pair()

    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> post(~p"/api/v1/gpg_key/revocation", %{
        "strategy" => "replace_key",
        "public_key" => pair2.public,
        "private_key" => pair2.private
      })

    assert %{"data" => %{"kind" => "replace_gpg_key"}} = json_response(conn, 202)
  end

  test "replace_with_generated_key starts a replacement with a one-time private key", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "replace_with_generated_key", algorithm: "ed25519"})
      )

    assert %{"data" => %{"transition" => transition, "private_key" => private}} =
             json_response(conn, 202)

    assert get_resp_header(conn, "retry-after") == ["2"]
    assert transition["kind"] == "replace_gpg_key"
    assert private =~ "BEGIN PGP PRIVATE KEY BLOCK"
  end

  test "algorithm is accepted only alongside replace_with_generated_key", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "clear_metadata_signing", algorithm: "ed25519"})
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "replace_with_generated_key rejects unknown algorithms and multipart bodies", ctx do
    bad_algorithm =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "replace_with_generated_key", algorithm: "rsa2048"})
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(bad_algorithm, 422)

    multipart =
      build_conn()
      |> bearer(ctx.token)
      |> put_req_header("content-type", "multipart/form-data; boundary=test")
      |> post(~p"/api/v1/gpg_key/revocation", %{"strategy" => "replace_with_generated_key"})

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(multipart, 422)
  end

  test "replace_with_generated_key without a stored key is not found", ctx do
    _ = ctx
    keyless = user_fixture()
    {token, _} = Accounts.create_session_token(keyless)

    conn =
      build_conn()
      |> bearer(token)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/gpg_key/revocation",
        Jason.encode!(%{strategy: "replace_with_generated_key"})
      )

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "unknown strategies are rejected", ctx do
    conn =
      ctx.conn
      |> bearer(ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/gpg_key/revocation", Jason.encode!(%{strategy: "nuke"}))

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "transition lookup is scoped to the owner", ctx do
    pair2 = generate_key_pair()

    {:accepted, transition} =
      DarkZenith.SigningTransitions.UserWide.start_replacement(
        ctx.user,
        pair2.public,
        pair2.private
      )

    other = user_fixture()
    {other_token, _} = Accounts.create_session_token(other)

    conn =
      build_conn() |> bearer(other_token) |> get(~p"/api/v1/gpg_key/transitions/#{transition.id}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end
end
