defmodule DarkZenith.EndToEnd.PaladinUploadTest do
  @moduledoc """
  The whole package lifecycle for a real-world package, driven only through
  the surfaces a client sees: the REST API creates the repository and the
  upload intent, the RPM bytes travel through the presigned PUT into
  (in-memory) B2, completion queues the pipeline, the Oban queues are
  drained the way the workers would run them, and the dnf-facing endpoint
  serves the resulting metadata and download.
  """

  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.FakeBucket

  @slug "paladin"
  @filename "paladin-0.1.0-1.x86_64.rpm"

  setup do
    owner = user_fixture()

    {:ok, {api_key, _}} =
      Accounts.create_api_key(owner, %{
        name: "ci",
        scopes: ~w(repo:create repo:read package:upload)
      })

    binary = paladin_binary()
    sha256 = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    %{bucket: FakeBucket.start!(), api_key: api_key, binary: binary, sha256: sha256}
  end

  defp api(api_key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> api_key)
  end

  # The client side of an object-storage transfer: the request a curl or
  # browser upload would make, routed to the in-memory bucket.
  defp transfer(method, url, opts) do
    {:ok, response} =
      Req.request(
        [method: method, url: url, plug: {Req.Test, DarkZenith.B2Stub}, retry: false] ++ opts
      )

    response
  end

  defp drain!(queue) do
    Oban.drain_queue(queue: queue, with_scheduled: true, with_safety: false)
  end

  test "creates the repository, uploads the RPM, and serves the processed package", ctx do
    # 1. Create the repository.
    created =
      ctx.api_key
      |> api()
      |> post(~p"/api/v1/repos", %{
        "slug" => @slug,
        "name" => "Paladin",
        "description" => "Simple, safe symmetric file encryption",
        "is_public" => true
      })

    assert %{"data" => %{"slug" => @slug, "package_count" => "0"}} = json_response(created, 201)

    # 2. Declare the upload and receive the presigned transfer.
    declared =
      ctx.api_key
      |> api()
      |> post(~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => Integer.to_string(byte_size(ctx.binary))
      })

    assert %{"data" => %{"id" => intent_id, "status" => "awaiting_upload"}, "upload" => upload} =
             json_response(declared, 201)

    assert upload["method"] == "PUT"

    # 3. PUT the bytes straight to object storage.
    put = transfer(:put, upload["url"], headers: upload["headers"], body: ctx.binary)
    assert put.status == 200
    [staged_version] = put.headers["x-amz-version-id"]

    assert [staging_key] = FakeBucket.keys(ctx.bucket)
    assert staging_key =~ ~r|^staging/uploads/[0-9a-f]{32}\.rpm$|

    # 4. Complete the intent with the exact staged version.
    completed =
      ctx.api_key
      |> api()
      |> post(~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}/complete", %{
        "generation" => upload["generation"],
        "version_id" => staged_version
      })

    assert %{"data" => %{"status" => "queued"}} = json_response(completed, 202)
    assert get_resp_header(completed, "retry-after") == ["2"]

    # 5. The processing pipeline runs: rpmkeys, parse, copy to the final key, commit.
    assert %{success: 1, failure: 0} = drain!(:rpm_processing)

    # 6. The intent reports success with the stored package.
    status =
      ctx.api_key |> api() |> get(~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}")

    assert %{"data" => %{"status" => "succeeded", "error" => nil, "package" => package}} =
             json_response(status, 200)

    assert get_resp_header(status, "retry-after") == []

    package_id = package["id"]
    assert package["name"] == "paladin"
    assert package["epoch"] == "0"
    assert package["version"] == "0.1.0"
    assert package["release"] == "1"
    assert package["arch"] == "x86_64"
    assert package["size_package"] == Integer.to_string(byte_size(ctx.binary))
    assert package["sha256"] == ctx.sha256
    assert package["license"] == "MIT OR Apache-2.0"
    assert package["rpm_sourcerpm"] == "paladin-0.1.0-1.src.rpm"
    assert package["requires_count"] == "1"
    assert package["files_count"] == "2"
    assert package["download_path"] == "/repos/#{@slug}/packages/#{package_id}/#{@filename}"

    # 7. The durable upload record, the package listing, and the repository agree.
    records = ctx.api_key |> api() |> get(~p"/api/v1/repos/#{@slug}/package-uploads")
    assert %{"data" => [record]} = json_response(records, 200)
    assert record["intent_id"] == intent_id
    assert record["outcome"] == "succeeded"
    assert record["live_status"] == nil
    assert record["nevra"] == "paladin-0:0.1.0-1.x86_64"
    assert record["final_size"] == Integer.to_string(byte_size(ctx.binary))
    assert record["original_filename"] == @filename

    packages = get(build_conn(), ~p"/api/v1/repos/#{@slug}/packages")

    assert %{"data" => [%{"id" => ^package_id}], "pagination" => %{"total" => "1"}} =
             json_response(packages, 200)

    shown = get(build_conn(), ~p"/api/v1/repos/#{@slug}")

    assert %{"data" => %{"package_count" => "1", "metadata_revision" => "1"}} =
             json_response(shown, 200)

    # 8. The dnf endpoint is behind until regeneration runs, then serves the package.
    stale = get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml")
    assert response(stale, 503) == "metadata_not_ready"
    assert get_resp_header(stale, "retry-after") == ["5"]

    assert %{success: 1, failure: 0} = drain!(:metadata)

    repomd = get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml")
    assert response(repomd, 200) =~ "<revision>1</revision>"

    primary = get(build_conn(), "/repos/#{@slug}/repodata/primary.xml.gz")
    primary_xml = :zlib.gunzip(response(primary, 200))
    assert primary_xml =~ ~s(packages="1")
    assert primary_xml =~ "<name>paladin</name>"
    assert primary_xml =~ "<arch>x86_64</arch>"
    assert primary_xml =~ ~s(<version epoch="0" ver="0.1.0" rel="1"/>)
    assert primary_xml =~ ctx.sha256
    assert primary_xml =~ ~s(<location href="packages/#{package_id}/#{@filename}"/>)

    filelists = get(build_conn(), "/repos/#{@slug}/repodata/filelists.xml.gz")
    assert :zlib.gunzip(response(filelists, 200)) =~ "<file>/usr/bin/paladin</file>"

    repo_file = get(build_conn(), "/repos/#{@slug}/dark-zenith.repo")
    assert response(repo_file, 200) =~ "[dark-zenith-#{@slug}]"

    # 9. The download redirects to the final object, whose bytes are the upload.
    redirect = get(build_conn(), package["download_path"])
    assert redirect.status == 302
    [location] = get_resp_header(redirect, "location")

    downloaded = transfer(:get, location, decode_body: false)
    assert downloaded.status == 200
    assert downloaded.body == ctx.binary

    # 10. Staging cleanup removes the staged version and leaves the final object.
    assert %{success: 1, failure: 0} = drain!(:cleanup)

    assert [final_key] = FakeBucket.keys(ctx.bucket)

    assert final_key =~
             ~r|^repos/#{@slug}/packages/#{package_id}/[0-9a-f-]{36}/paladin-0-0\.1\.0-1\.x86_64\.rpm$|

    assert location =~ final_key
    assert FakeBucket.fetch(ctx.bucket, final_key).body == ctx.binary
  end
end
