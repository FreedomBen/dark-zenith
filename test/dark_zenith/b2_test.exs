defmodule DarkZenith.B2Test do
  use ExUnit.Case, async: true

  alias DarkZenith.B2

  defp config(overrides \\ []) do
    struct!(
      B2.Config,
      Keyword.merge(
        [
          key_id: "test-key-id",
          application_key: "test-secret",
          bucket: "dz-bucket",
          endpoint: "https://s3.eu-central-003.backblazeb2.com",
          region: "eu-central-003",
          req_options: [plug: {Req.Test, DarkZenith.B2Stub}, retry: false]
        ],
        overrides
      )
    )
  end

  describe "presigned URLs" do
    test "staging upload URLs sign the method, key, content type, and length" do
      url =
        B2.staging_upload_url(config(), "staging/uploads/abc.rpm", 12_345,
          ttl: 3600,
          now: ~U[2026-08-30 12:00:00Z]
        )

      assert url =~ "https://s3.eu-central-003.backblazeb2.com/dz-bucket/staging/uploads/abc.rpm?"
      assert url =~ "X-Amz-Expires=3600"
      assert url =~ "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost"
      assert url =~ "X-Amz-Signature="
    end

    test "download URLs address the exact version and differ by method" do
      get_url =
        B2.signed_get_url(config(), "repos/x/pkg.rpm", "4_zversion",
          ttl: 60,
          now: ~U[2026-08-30 12:00:00Z]
        )

      head_url =
        B2.signed_head_url(config(), "repos/x/pkg.rpm", "4_zversion",
          ttl: 60,
          now: ~U[2026-08-30 12:00:00Z]
        )

      assert get_url =~ "versionId=4_zversion"
      assert head_url =~ "versionId=4_zversion"

      get_sig = URI.decode_query(URI.parse(get_url).query)["X-Amz-Signature"]
      head_sig = URI.decode_query(URI.parse(head_url).query)["X-Amz-Signature"]
      refute get_sig == head_sig
    end
  end

  describe "head_object/3" do
    test "returns the object description for the exact version" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        assert conn.method == "HEAD"
        assert conn.request_path == "/dz-bucket/staging/uploads/abc.rpm"
        assert conn.query_string =~ "versionId=4_zv1"
        assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        assert authorization =~ "AWS4-HMAC-SHA256 Credential=test-key-id/"

        conn
        |> Plug.Conn.put_resp_header("content-length", "12345")
        |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
        |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zv1")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:ok, head} = B2.head_object(config(), "staging/uploads/abc.rpm", "4_zv1")
      assert head.content_length == 12_345
      assert head.content_type == "application/x-rpm"
      assert head.version_id == "4_zv1"
      assert head.user_metadata == %{}
    end

    test "collects user metadata and forbidden content headers" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "10")
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.put_resp_header("content-disposition", "attachment")
        |> Plug.Conn.put_resp_header("x-amz-meta-evil", "")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:ok, head} = B2.head_object(config(), "k", "v")
      assert head.forbidden_headers["content-disposition"] == "attachment"
      assert head.user_metadata == %{"x-amz-meta-evil" => ""}
    end

    test "maps 404 to not_found and other failures to storage_unavailable" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, :not_found} = B2.head_object(config(), "k", "v")

      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, :storage_unavailable} = B2.head_object(config(), "k", "v")

      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :storage_unavailable} = B2.head_object(config(), "k", "v")
    end
  end

  describe "verify_object_contract/3" do
    defp head(overrides \\ %{}) do
      Map.merge(
        %{
          content_length: 100,
          content_type: "application/x-rpm",
          version_id: "v",
          forbidden_headers: %{},
          user_metadata: %{}
        },
        overrides
      )
    end

    test "accepts a clean object of the expected length" do
      assert :ok = B2.verify_object_contract(head(), 100)
    end

    test "rejects length, content-type, forbidden-header, and metadata violations" do
      assert {:error, :length_mismatch} = B2.verify_object_contract(head(), 99)

      assert {:error, :content_type_mismatch} =
               B2.verify_object_contract(head(%{content_type: "text/plain"}), 100)

      assert {:error, :forbidden_headers} =
               B2.verify_object_contract(
                 head(%{forbidden_headers: %{"cache-control" => "public"}}),
                 100
               )

      assert {:error, :forbidden_metadata} =
               B2.verify_object_contract(head(%{user_metadata: %{"x-amz-meta-a" => ""}}), 100)
    end
  end

  describe "put_object/4" do
    test "uploads with the exact content type and returns the new version" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/dz-bucket/repos/x/final.rpm"
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-rpm"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "rpm bytes"

        conn
        |> Plug.Conn.put_resp_header("x-amz-version-id", "4_znew")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:ok, "4_znew"} = B2.put_object(config(), "repos/x/final.rpm", "rpm bytes")
    end

    test "a response without a version id is a storage failure" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert {:error, :storage_unavailable} = B2.put_object(config(), "k", "data")
    end
  end

  describe "copy_object/5" do
    test "copies the exact source version with replaced metadata" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/dz-bucket/repos/x/final.rpm"

        assert Plug.Conn.get_req_header(conn, "x-amz-copy-source") ==
                 ["/dz-bucket/staging/uploads/abc.rpm?versionId=4_zsrc"]

        assert Plug.Conn.get_req_header(conn, "x-amz-metadata-directive") == ["REPLACE"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-rpm"]

        conn
        |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zdest")
        |> Plug.Conn.send_resp(200, """
        <?xml version="1.0" encoding="UTF-8"?>
        <CopyObjectResult><ETag>"abc"</ETag></CopyObjectResult>
        """)
      end)

      assert {:ok, "4_zdest"} =
               B2.copy_object(config(), "repos/x/final.rpm", "staging/uploads/abc.rpm", "4_zsrc")
    end

    test "a 200 response carrying an embedded error is a storage failure" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zdest")
        |> Plug.Conn.send_resp(200, "<Error><Code>InternalError</Code></Error>")
      end)

      assert {:error, :storage_unavailable} =
               B2.copy_object(config(), "d", "s", "v")
    end
  end

  describe "delete_version/3" do
    test "deletes the exact version and treats absence as success" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        assert conn.method == "DELETE"
        assert conn.query_string =~ "versionId=4_zv"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = B2.delete_version(config(), "k", "4_zv")

      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert :ok = B2.delete_version(config(), "k", "4_zv")

      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      assert {:error, :storage_unavailable} = B2.delete_version(config(), "k", "4_zv")
    end
  end

  describe "list_object_versions/3" do
    test "paginates versions and delete markers across truncated pages" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        page = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        assert conn.query_string =~ "versions"
        assert conn.query_string =~ "prefix=repos%2F"

        body =
          case page do
            0 ->
              assert not (conn.query_string =~ "key-marker")

              """
              <?xml version="1.0" encoding="UTF-8"?>
              <ListVersionsResult>
                <IsTruncated>true</IsTruncated>
                <NextKeyMarker>repos/b</NextKeyMarker>
                <NextVersionIdMarker>4_zv2</NextVersionIdMarker>
                <Version><Key>repos/a</Key><VersionId>4_zv1</VersionId></Version>
                <Version><Key>repos/b</Key><VersionId>4_zv2</VersionId></Version>
              </ListVersionsResult>
              """

            1 ->
              assert conn.query_string =~ "key-marker=repos%2Fb"
              assert conn.query_string =~ "version-id-marker=4_zv2"

              """
              <?xml version="1.0" encoding="UTF-8"?>
              <ListVersionsResult>
                <IsTruncated>false</IsTruncated>
                <Version><Key>repos/c</Key><VersionId>4_zv3</VersionId><LastModified>2026-08-30T10:00:00.000Z</LastModified></Version>
                <DeleteMarker><Key>repos/d</Key><VersionId>4_zv4</VersionId></DeleteMarker>
              </ListVersionsResult>
              """
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, entries} = B2.list_all_object_versions(config(), "repos/")

      assert entries == [
               %{key: "repos/a", version_id: "4_zv1", delete_marker?: false, last_modified: nil},
               %{key: "repos/b", version_id: "4_zv2", delete_marker?: false, last_modified: nil},
               %{
                 key: "repos/c",
                 version_id: "4_zv3",
                 delete_marker?: false,
                 last_modified: ~U[2026-08-30 10:00:00.000Z]
               },
               %{key: "repos/d", version_id: "4_zv4", delete_marker?: true, last_modified: nil}
             ]
    end

    test "a failed page returns storage_unavailable" do
      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, :storage_unavailable} = B2.list_all_object_versions(config(), "x/")
    end
  end
end
