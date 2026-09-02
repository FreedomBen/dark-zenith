defmodule DarkZenith.UploadsTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Storage.Reservation
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.{Intent, Records}
  alias DarkZenith.Workers.{StagingCleanup, UploadProcessing}

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp create!(ctx, attrs \\ %{}) do
    {:ok, intent, upload} =
      Uploads.create_intent(
        ctx.owner,
        ctx.repo,
        Map.merge(%{filename: "pkg.rpm", size: 1000, mode: "api"}, attrs)
      )

    {intent, upload}
  end

  describe "create_intent/3" do
    test "creates an awaiting intent with a reservation and presigned upload", ctx do
      {intent, upload} = create!(ctx)

      assert intent.status == "awaiting_upload"
      assert intent.mode == "api"
      assert intent.declared_size == 1000
      assert intent.upload_generation == 1
      assert String.starts_with?(intent.staging_path, "staging/uploads/")
      # 128 bits of entropy = 32 hex characters plus the extension.
      assert intent.staging_path =~ ~r|^staging/uploads/[0-9a-f]{32}\.rpm$|
      assert intent.package_id

      reservation = Repo.get!(Reservation, intent.reservation_id)
      assert reservation.reserved_bytes == 1000
      assert reservation.user_id == ctx.owner.id

      assert upload.generation == 1
      assert upload.method == "PUT"
      assert upload.url =~ intent.staging_path
      assert upload.url =~ "X-Amz-Signature="
      assert upload.headers == %{"Content-Type" => "application/x-rpm"}
      assert upload.content_length == 1000

      two_hours = DateTime.add(DateTime.utc_now(:second), 2, :hour)
      assert_in_delta DateTime.to_unix(intent.expires_at), DateTime.to_unix(two_hours), 5
    end

    test "reduces the filename to its final path component", ctx do
      {intent, _} = create!(ctx, %{filename: "C:\\dir\\sub/legit name.rpm"})
      assert intent.original_filename == "legit name.rpm"
    end

    test "admins upload against the owner's quota", ctx do
      admin = admin_fixture()

      {:ok, intent, _} =
        Uploads.create_intent(admin, ctx.repo, %{filename: "a.rpm", size: 10, mode: "api"})

      assert intent.user_id == admin.id
      assert Repo.get!(Reservation, intent.reservation_id).user_id == ctx.owner.id
    end

    test "rejects invalid filenames and sizes", ctx do
      for filename <- ["", "   ", "dir/", "bad\x01name.rpm", String.duplicate("a", 256)] do
        assert {:error, :invalid_filename} =
                 Uploads.create_intent(ctx.owner, ctx.repo, %{
                   filename: filename,
                   size: 10,
                   mode: "api"
                 })
      end

      assert {:error, :invalid_size} =
               Uploads.create_intent(ctx.owner, ctx.repo, %{
                 filename: "a.rpm",
                 size: 0,
                 mode: "api"
               })

      assert {:error, :payload_too_large} =
               Uploads.create_intent(ctx.owner, ctx.repo, %{
                 filename: "a.rpm",
                 size: 536_870_913,
                 mode: "api"
               })
    end

    test "non-managers cannot create intents", ctx do
      stranger = user_fixture()

      assert {:error, :forbidden} =
               Uploads.create_intent(stranger, ctx.repo, %{
                 filename: "a.rpm",
                 size: 10,
                 mode: "api"
               })
    end

    test "quota exhaustion surfaces as quota_exceeded", ctx do
      {1, _} =
        Repo.update_all(from(u in DarkZenith.Accounts.User, where: u.id == ^ctx.owner.id),
          set: [storage_bytes: 53_687_091_200]
        )

      assert {:error, :quota_exceeded} =
               Uploads.create_intent(ctx.owner, ctx.repo, %{
                 filename: "a.rpm",
                 size: 10,
                 mode: "api"
               })
    end
  end

  describe "refresh_intent/2" do
    test "refreshes only an awaiting intent whose URL has expired", ctx do
      {intent, _} = create!(ctx)

      # URL still valid: refused.
      assert {:error, :upload_state} = Uploads.refresh_intent(ctx.owner, intent)

      expire_url!(intent)

      assert {:ok, refreshed, upload} = Uploads.refresh_intent(ctx.owner, reload(intent))
      assert refreshed.upload_generation == 2
      assert refreshed.staging_path != intent.staging_path
      assert upload.generation == 2

      # The abandoned staging key is scheduled for cleanup.
      assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})
    end

    test "refuses a refresh with less than a minute before intent expiry", ctx do
      {intent, _} = create!(ctx)
      expire_url!(intent)

      soon = DateTime.add(DateTime.utc_now(:second), 30, :second)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: soon])

      assert {:error, :upload_state} = Uploads.refresh_intent(ctx.owner, reload(intent))
    end
  end

  describe "complete_intent/4" do
    setup ctx do
      {intent, _} = create!(ctx)
      %{intent: intent}
    end

    test "accepts the exact verified version and queues processing", %{intent: intent} = ctx do
      stub_head_object(intent, 1000)

      assert {:ok, completed} =
               Uploads.complete_intent(ctx.owner, intent, 1, "4_zaccepted")

      assert completed.status == "queued"
      assert completed.staging_version_id == "4_zaccepted"
      assert completed.upload_url_expires_at == nil
      assert completed.expires_at == nil
      assert completed.next_attempt_at

      assert_enqueued(worker: UploadProcessing, args: %{intent_id: intent.id})
    end

    test "is idempotent for the accepted generation and version", %{intent: intent} = ctx do
      stub_head_object(intent, 1000)
      {:ok, _} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zaccepted")

      assert {:ok, %Intent{status: "queued"}} =
               Uploads.complete_intent(ctx.owner, reload(intent), 1, "4_zaccepted")

      # A different version for the accepted intent conflicts.
      assert {:error, :upload_state} =
               Uploads.complete_intent(ctx.owner, reload(intent), 1, "4_zother")
    end

    test "rejects a stale generation", %{intent: intent} = ctx do
      expire_url!(intent)
      {:ok, refreshed, _} = Uploads.refresh_intent(ctx.owner, reload(intent))

      stub_head_object(refreshed, 1000)
      assert {:error, :upload_state} = Uploads.complete_intent(ctx.owner, refreshed, 1, "4_zv")
      assert {:ok, _} = Uploads.complete_intent(ctx.owner, reload(intent), 2, "4_zv")
    end

    test "a contract mismatch deletes the version and stays awaiting", %{intent: intent} = ctx do
      Req.Test.stub(DarkZenith.B2Stub, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-length", "999")
            |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
            |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zbad")
            |> Plug.Conn.send_resp(200, "")

          "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:error, :validation_failed} =
               Uploads.complete_intent(ctx.owner, intent, 1, "4_zbad")

      assert reload(intent).status == "awaiting_upload"
    end

    test "a nonexistent version is a validation failure", %{intent: intent} = ctx do
      Req.Test.stub(DarkZenith.B2Stub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :validation_failed} =
               Uploads.complete_intent(ctx.owner, intent, 1, "4_zmissing")
    end

    test "a version_id with control characters is rejected without B2 contact",
         %{intent: intent} = ctx do
      for bad <- ["4_z\nv", "4_z\tv", "\x00", "4_z\x7Fv"] do
        assert {:error, :validation_failed} =
                 Uploads.complete_intent(ctx.owner, intent, 1, bad)
      end

      assert reload(intent).status == "awaiting_upload"
    end

    test "an overdue intent is atomically expired instead", %{intent: intent} = ctx do
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])

      assert {:error, :upload_state} =
               Uploads.complete_intent(ctx.owner, reload(intent), 1, "4_zv")

      expired = reload(intent)
      assert expired.status == "expired"
      assert expired.reservation_id == nil
      assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})
    end
  end

  describe "cancel_intent/2" do
    test "cancels an active intent, releasing the reservation and staging", ctx do
      {intent, _} = create!(ctx)
      reservation_id = intent.reservation_id

      assert {:ok, canceled} = Uploads.cancel_intent(ctx.owner, intent)
      assert canceled.status == "canceled"
      assert canceled.reservation_id == nil
      refute Repo.get(Reservation, reservation_id)
      assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})

      # Repeating cancellation is an idempotent success (DESIGN.md: DELETE
      # package-uploads), not a conflict.
      assert {:ok, %Intent{status: "canceled"}} = Uploads.cancel_intent(ctx.owner, reload(intent))
    end

    test "cancelling an already failed or expired intent is idempotent", ctx do
      for {status, extra} <- [{"failed", [last_error_code: "validation_failed"]}, {"expired", []}] do
        {intent, _} = create!(ctx)
        terminalize_for_test!(intent, status, extra)

        assert {:ok, %Intent{status: ^status}} =
                 Uploads.cancel_intent(ctx.owner, reload(intent))
      end
    end

    test "cancelling a succeeded intent conflicts", ctx do
      {intent, _} = create!(ctx)
      terminalize_for_test!(intent, "succeeded", [])

      assert {:error, :upload_state} = Uploads.cancel_intent(ctx.owner, reload(intent))
    end
  end

  # Forces an intent into a terminal state the way the pipeline would,
  # satisfying the upload_intents_state check constraint.
  defp terminalize_for_test!(intent, status, extra) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
      set:
        [
          status: status,
          reservation_id: nil,
          completed_at: now,
          next_attempt_at: nil,
          lease_token: nil,
          lease_expires_at: nil,
          expires_at: nil,
          upload_url_expires_at: nil
        ] ++ extra
    )
  end

  describe "sweeps" do
    test "expire_overdue expires overdue awaiting rows only", ctx do
      {overdue, _} = create!(ctx)
      {fresh, _} = create!(ctx)

      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)
      Repo.update_all(from(i in Intent, where: i.id == ^overdue.id), set: [expires_at: past])

      Uploads.expire_overdue()

      assert reload(overdue).status == "expired"
      assert reload(fresh).status == "awaiting_upload"
    end

    test "requeue_expired_leases returns a crashed processing claim to queued with backoff",
         ctx do
      {intent, _} = create!(ctx)
      stub_head_object(intent, 1000)
      {:ok, _} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zv")

      now = DateTime.utc_now(:second)
      past = DateTime.add(now, -1, :minute)

      {1, _} =
        Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
          set: [
            status: "processing",
            lease_token: Ecto.UUID.generate(),
            lease_expires_at: past,
            next_attempt_at: nil,
            attempts: 3
          ]
        )

      # The crashed claim's own job has run its course (its Oban retry saw
      # `processing` and completed), so the sweep's replacement is the only
      # live job for the intent; the worker is unique on intent_id.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "DarkZenith.Workers.UploadProcessing"),
        set: [state: "completed"]
      )

      Uploads.requeue_expired_leases()

      requeued = reload(intent)
      assert requeued.status == "queued"
      assert requeued.lease_token == nil
      assert requeued.attempts == 3

      # Background Retry Policy after failed attempt 3: 30 * 2^2 seconds.
      assert_in_delta DateTime.diff(requeued.next_attempt_at, now), 120, 5

      assert_enqueued(
        worker: UploadProcessing,
        args: %{intent_id: intent.id},
        scheduled_at: {requeued.next_attempt_at, delta: 5}
      )

      # The reservation lease was renewed ahead.
      reservation = Repo.get!(Reservation, requeued.reservation_id)
      assert DateTime.compare(reservation.expires_at, DateTime.add(now, 1, :hour)) == :gt
    end

    test "requeue_expired_leases fails an intent whose expired claim exhausted its budget",
         ctx do
      {intent, _} = create!(ctx)
      stub_head_object(intent, 1000)
      {:ok, _} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zv")

      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

      {1, _} =
        Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
          set: [
            status: "processing",
            lease_token: Ecto.UUID.generate(),
            lease_expires_at: past,
            next_attempt_at: nil,
            attempts: 20
          ]
        )

      Uploads.requeue_expired_leases()

      failed = reload(intent)
      assert failed.status == "failed"
      assert failed.last_error_code == "internal_error"
      assert failed.attempts == 20
      assert failed.completed_at
      assert failed.lease_token == nil
      assert failed.reservation_id == nil
      refute Repo.get(Reservation, intent.reservation_id)
      assert_enqueued(worker: StagingCleanup, args: %{staging_path: intent.staging_path})

      record = Records.get_by_intent(intent.id)
      assert record.outcome == "failed"
      assert record.error_code == "internal_error"

      # The sweep is a system actor: the terminal event has no actor.
      event =
        Enum.find(DarkZenith.Audit.list_events(), &(&1.metadata["result"] == "internal_error"))

      assert event.action == "package.upload"
      assert event.actor_id == nil
      assert event.metadata["intent_id"] == intent.id
    end

    test "delete_old_terminal removes day-old terminal rows", ctx do
      {intent, _} = create!(ctx)
      {:ok, canceled} = Uploads.cancel_intent(ctx.owner, intent)

      old = DateTime.add(DateTime.utc_now(:second), -25, :hour)

      Repo.update_all(from(i in Intent, where: i.id == ^canceled.id),
        set: [completed_at: old]
      )

      Uploads.delete_old_terminal()
      refute Repo.get(Intent, intent.id)
    end
  end

  defp reload(intent), do: Repo.get!(Intent, intent.id)

  defp expire_url!(intent) do
    past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

    Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
      set: [upload_url_expires_at: past]
    )
  end

  defp stub_head_object(intent, length) do
    path = "/dz-bucket/" <> intent.staging_path

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == path

      conn
      # Plug's default cache-control would trip the forbidden-header check.
      |> Plug.Conn.delete_resp_header("cache-control")
      |> Plug.Conn.put_resp_header("content-length", Integer.to_string(length))
      |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
      |> Plug.Conn.put_resp_header("x-amz-version-id", "any")
      |> Plug.Conn.send_resp(200, "")
    end)
  end
end
