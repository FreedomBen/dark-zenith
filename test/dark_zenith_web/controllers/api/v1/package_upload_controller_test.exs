defmodule DarkZenithWeb.Api.V1.PackageUploadControllerTest do
  use DarkZenithWeb.ConnCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Uploads

  setup %{conn: conn} do
    owner = user_fixture()
    repo = repository_fixture(owner)

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      owner: owner,
      repo: repo,
      token: session_token_for(owner)
    }
  end

  defp session_token_for(user) do
    {plaintext, _} = Accounts.create_session_token(user)
    plaintext
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp api_key_for(user, scopes) do
    {:ok, {plaintext, _}} = Accounts.create_api_key(user, %{name: "k", scopes: scopes})
    plaintext
  end

  describe "POST /api/v1/repos/:slug/package-uploads" do
    test "creates an intent with the ephemeral upload object", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads", %{
          "filename" => "nginx.rpm",
          "size" => "623104"
        })

      assert %{"data" => data, "upload" => upload} = json_response(conn, 201)
      assert data["status"] == "awaiting_upload"
      assert data["original_filename"] == "nginx.rpm"
      assert data["declared_size"] == "623104"
      assert data["mode"] == "api"
      assert data["error"] == nil
      assert data["package"] == nil
      refute Map.has_key?(data, "staging_path")

      assert upload["generation"] == 1
      assert upload["method"] == "PUT"
      assert upload["url"] =~ "X-Amz-Signature="
      assert upload["headers"] == %{"Content-Type" => "application/x-rpm"}
      assert upload["content_length"] == "623104"
    end

    test "rejects a client-supplied mode and non-string sizes", ctx do
      with_mode =
        ctx.conn
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads", %{
          "filename" => "a.rpm",
          "size" => "10",
          "mode" => "web_preview"
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(with_mode, 422)

      numeric_size =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads", %{
          "filename" => "a.rpm",
          "size" => 10
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(numeric_size, 422)
    end

    test "an oversized declaration is 413", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads", %{
          "filename" => "a.rpm",
          "size" => "5368709121"
        })

      assert %{"error" => %{"code" => "payload_too_large"}} = json_response(conn, 413)
    end

    test "requires package:upload on API keys", ctx do
      conn =
        ctx.conn
        |> bearer(api_key_for(ctx.owner, ["repo:read"]))
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads", %{
          "filename" => "a.rpm",
          "size" => "10"
        })

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end
  end

  describe "status, refresh, complete, cancel" do
    setup ctx do
      {:ok, intent, _upload} =
        Uploads.create_intent(ctx.owner, ctx.repo, %{filename: "a.rpm", size: 1000, mode: "api"})

      %{intent: intent}
    end

    test "status polling carries Retry-After while active", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> get(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{ctx.intent.id}")

      assert %{"data" => %{"status" => "awaiting_upload"}} = json_response(conn, 200)
      assert get_resp_header(conn, "retry-after") == []
    end

    test "completion returns 202 with Retry-After 2", ctx do
      path = "/dz-bucket/" <> ctx.intent.staging_path

      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        assert conn.request_path == path

        conn
        |> Plug.Conn.delete_resp_header("cache-control")
        |> Plug.Conn.put_resp_header("content-length", "1000")
        |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
        |> Plug.Conn.send_resp(200, "")
      end)

      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{ctx.intent.id}/complete", %{
          "generation" => 1,
          "version_id" => "4_zv"
        })

      assert %{"data" => %{"status" => "queued"}} = json_response(conn, 202)
      assert get_resp_header(conn, "retry-after") == ["2"]
      assert_enqueued(worker: DarkZenith.Workers.UploadProcessing)
    end

    test "refresh before URL expiry conflicts", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{ctx.intent.id}/refresh")

      assert %{"error" => %{"code" => "conflict_upload_state"}} = json_response(conn, 409)
    end

    test "cancel returns 204 and later completion conflicts", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> delete(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{ctx.intent.id}")

      assert response(conn, 204) == ""

      completed =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> bearer(ctx.token)
        |> post(~p"/api/v1/repos/#{ctx.repo.slug}/package-uploads/#{ctx.intent.id}/complete", %{
          "generation" => 1,
          "version_id" => "4_zv"
        })

      assert %{"error" => %{"code" => "conflict_upload_state"}} = json_response(completed, 409)
    end

    test "intents under another repository are nonexistent", ctx do
      other = repository_fixture(ctx.owner)

      conn =
        ctx.conn
        |> bearer(ctx.token)
        |> get(~p"/api/v1/repos/#{other.slug}/package-uploads/#{ctx.intent.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end
end
