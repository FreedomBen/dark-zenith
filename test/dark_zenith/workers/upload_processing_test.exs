defmodule DarkZenith.Workers.UploadProcessingTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Packages.Package
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Storage.Reservation
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.{MetadataRegeneration, StagingCleanup, UploadProcessing}

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner), binary: v4_binary()}
  end

  defp queued_intent!(ctx, binary, mode \\ "api") do
    {:ok, intent, _upload} =
      Uploads.create_intent(ctx.owner, ctx.repo, %{
        filename: "upload.rpm",
        size: byte_size(binary),
        mode: mode
      })

    stub_pipeline(intent, binary)
    {:ok, queued} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zstaged")
    queued
  end

  defp stub_pipeline(intent, binary, opts \\ []) do
    staging = "/dz-bucket/" <> intent.staging_path
    length = Integer.to_string(byte_size(binary))
    copy_status = Keyword.get(opts, :copy_status, 200)

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      case {conn.method, conn.request_path} do
        {"HEAD", ^staging} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", length)
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zstaged")
          |> Plug.Conn.send_resp(200, "")

        {"GET", ^staging} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.send_resp(200, binary)

        {"PUT", "/dz-bucket/repos/" <> _} when copy_status == 200 ->
          assert [source] = Plug.Conn.get_req_header(conn, "x-amz-copy-source")
          assert source =~ "versionId=4_zstaged"
          assert Plug.Conn.get_req_header(conn, "x-amz-metadata-directive") == ["REPLACE"]

          conn
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zfinal")
          |> Plug.Conn.send_resp(200, "<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")

        {"PUT", "/dz-bucket/repos/" <> _} ->
          Plug.Conn.send_resp(conn, copy_status, "")

        {"HEAD", "/dz-bucket/repos/" <> _} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", length)
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zfinal")
          |> Plug.Conn.send_resp(200, "")

        {"DELETE", _} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end

  defp reload(intent), do: Repo.get!(Intent, intent.id)

  test "processes an API upload end to end into a package row", ctx do
    intent = queued_intent!(ctx, ctx.binary)

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    done = reload(intent)
    assert done.status == "succeeded"
    assert done.reservation_id == nil
    assert done.completed_at
    refute Repo.get(Reservation, intent.reservation_id)

    package = Repo.get!(Package, intent.package_id)
    assert package.name == "dz-fixture"
    assert package.epoch == 2
    assert package.arch == "noarch"
    assert package.size_package == byte_size(ctx.binary)

    assert package.sha256 ==
             :crypto.hash(:sha256, ctx.binary) |> Base.encode16(case: :lower)

    assert package.storage_path =~
             ~r|^repos/#{ctx.repo.slug}/packages/#{intent.package_id}/[0-9a-f-]{36}/dz-fixture-2-1\.2\.3-4\.noarch\.rpm$|

    assert package.storage_version_id == "4_zfinal"
    assert length(package.requires) == 6

    repo = Repo.get!(Repository, ctx.repo.id)
    assert repo.package_count == 1
    assert repo.metadata_revision == 1

    # Counters equal the counting-sink sums for the stored row.
    sizes = DarkZenith.Repodata.entry_open_sizes(package)
    overhead = DarkZenith.Repodata.document_overhead(1)
    assert repo.primary_open_bytes == sizes.primary + overhead.primary
    assert repo.filelists_open_bytes == sizes.filelists + overhead.filelists
    assert repo.other_open_bytes == sizes.other + overhead.other

    owner = Repo.get!(DarkZenith.Accounts.User, ctx.owner.id)
    assert owner.storage_bytes == byte_size(ctx.binary)

    assert_enqueued(worker: MetadataRegeneration, args: %{repository_id: ctx.repo.id})
    assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})

    assert Enum.any?(
             DarkZenith.Audit.list_events(),
             &(&1.action == "package.upload" and &1.metadata["result"] == "succeeded")
           )
  end

  test "regeneration after processing yields dnf-consumable metadata", ctx do
    intent = queued_intent!(ctx, ctx.binary)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => ctx.repo.id})

    cache = Repo.get_by!(DarkZenith.Repositories.MetadataCache, repository_id: ctx.repo.id)
    assert cache.source_revision == 1
    assert :zlib.gunzip(cache.primary_xml_gz) =~ "<name>dz-fixture</name>"
  end

  test "a package with a BAD digest fails terminally as validation_failed", ctx do
    size = byte_size(ctx.binary)

    corrupted =
      binary_part(ctx.binary, 0, size - 10) <> <<0xFF>> <> binary_part(ctx.binary, size - 9, 9)

    intent = queued_intent!(ctx, corrupted)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = reload(intent)
    assert failed.status == "failed"
    assert failed.last_error_code == "validation_failed"
    assert failed.reservation_id == nil
    refute Repo.get(Package, intent.package_id)
    assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})
  end

  test "bytes that are not an RPM fail as validation_failed", ctx do
    junk = :crypto.strong_rand_bytes(2048)
    intent = queued_intent!(ctx, junk)

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    assert reload(intent).last_error_code == "validation_failed"
  end

  test "a duplicate NEVRA fails as conflict_duplicate_package", ctx do
    DarkZenith.PackagesFixtures.insert_package_from_rpm!(ctx.repo, ctx.binary)

    intent = queued_intent!(ctx, ctx.binary)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = reload(intent)
    assert failed.status == "failed"
    assert failed.last_error_code == "conflict_duplicate_package"
  end

  test "an infrastructure failure requeues with backoff and durable budget", ctx do
    {:ok, intent, _} =
      Uploads.create_intent(ctx.owner, ctx.repo, %{
        filename: "u.rpm",
        size: byte_size(ctx.binary),
        mode: "api"
      })

    stub_pipeline(intent, ctx.binary)
    {:ok, _} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zstaged")
    stub_pipeline(intent, ctx.binary, copy_status: 500)

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    requeued = reload(intent)
    assert requeued.status == "queued"
    assert requeued.attempts == 1
    assert requeued.last_error_code == "storage_unavailable"

    # Backoff after attempt 1 is 30 seconds.
    delta = DateTime.diff(requeued.next_attempt_at, DateTime.utc_now(:second))
    assert_in_delta delta, 30, 5

    # The reservation survives between attempts.
    assert Repo.get(Reservation, requeued.reservation_id)
  end

  test "the twentieth failed claim is terminal with the sanitized code", ctx do
    intent = queued_intent!(ctx, ctx.binary)
    stub_pipeline(intent, ctx.binary, copy_status: 500)

    {1, _} =
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [attempts: 19])

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = reload(intent)
    assert failed.status == "failed"
    assert failed.last_error_code == "storage_unavailable"
    assert failed.attempts == 20
  end

  test "web preview stops at preview_ready and finishes after confirmation", ctx do
    intent = queued_intent!(ctx, ctx.binary, "web_preview")

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    preview = reload(intent)
    assert preview.status == "preview_ready"
    assert preview.preview_metadata["name"] == "dz-fixture"
    assert preview.preview_metadata["epoch"] == 2
    assert length(preview.preview_metadata["requires"]) == 6

    fifteen = DateTime.add(DateTime.utc_now(:second), 15, :minute)
    assert_in_delta DateTime.to_unix(preview.expires_at), DateTime.to_unix(fifteen), 10

    reservation = Repo.get!(Reservation, preview.reservation_id)
    assert_in_delta DateTime.to_unix(reservation.expires_at), DateTime.to_unix(fifteen), 10

    # The staging object is retained for final processing.
    refute_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})

    {:ok, confirmed} = Uploads.confirm_preview(ctx.owner, preview)
    assert confirmed.status == "queued"
    assert confirmed.attempts == 0

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    assert reload(intent).status == "succeeded"
    assert Repo.get!(Package, intent.package_id).name == "dz-fixture"
  end

  test "only the initiating user can confirm a preview", ctx do
    intent = queued_intent!(ctx, ctx.binary, "web_preview")
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    admin = admin_fixture()
    assert {:error, :forbidden} = Uploads.confirm_preview(admin, reload(intent))
  end

  test "sign_rpms with no configured owner key rejects the upload", ctx do
    {1, _} =
      Repo.update_all(from(r in Repository, where: r.id == ^ctx.repo.id),
        set: [
          sign_rpms: true,
          gpg_key_fingerprint: String.duplicate("A", 40),
          rpm_signing_state: "enabled"
        ]
      )

    intent = queued_intent!(ctx, ctx.binary)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = reload(intent)
    assert failed.status == "failed"
    assert failed.last_error_code == "validation_failed"
  end

  test "an undecryptable owner key requeues as signing_unavailable", ctx do
    DarkZenith.RepositoriesFixtures.put_user_gpg_fingerprint(ctx.owner)

    {1, _} =
      Repo.update_all(from(r in Repository, where: r.id == ^ctx.repo.id),
        set: [
          sign_rpms: true,
          gpg_key_fingerprint: String.duplicate("A", 40),
          rpm_signing_state: "enabled"
        ]
      )

    intent = queued_intent!(ctx, ctx.binary)
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    requeued = reload(intent)
    assert requeued.status == "queued"
    assert requeued.last_error_code == "signing_unavailable"
  end

  test "claiming skips intents that are not due", ctx do
    intent = queued_intent!(ctx, ctx.binary)

    future = DateTime.add(DateTime.utc_now(:second), 1, :hour)

    {1, _} =
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
        set: [next_attempt_at: future]
      )

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    assert reload(intent).status == "queued"
  end
end

defmodule DarkZenith.Workers.UploadProcessingLimitsTest do
  # Not async: overrides global limit settings.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.UploadProcessing

  test "a package-count limit rejection is terminal with the conflict code" do
    previous = Application.get_env(:dark_zenith, :max_repository_packages)
    Application.put_env(:dark_zenith, :max_repository_packages, 0)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_repository_packages, previous) end)

    owner = user_fixture()
    repo = repository_fixture(owner)
    binary = v4_binary()

    {:ok, intent, _} =
      Uploads.create_intent(owner, repo, %{
        filename: "u.rpm",
        size: byte_size(binary),
        mode: "api"
      })

    staging = "/dz-bucket/" <> intent.staging_path

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      case {conn.method, conn.request_path} do
        {"HEAD", ^staging} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(binary)))
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.send_resp(200, "")

        {"GET", ^staging} ->
          Plug.Conn.send_resp(conn, 200, binary)

        {"DELETE", _} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    {:ok, _} = Uploads.complete_intent(owner, intent, 1, "4_zstaged")
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})

    failed = Repo.get!(Intent, intent.id)
    assert failed.status == "failed"
    assert failed.last_error_code == "conflict_repository_metadata_limit_exceeded"
  end
end
