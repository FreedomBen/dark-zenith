defmodule DarkZenithWeb.UploadLiveTest do
  use DarkZenithWeb.ConnCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.B2StubHelpers
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.UploadProcessing

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner), binary: v4_binary()}
  end

  defp mount_upload(conn, owner, repo) do
    {:ok, lv, _html} =
      conn
      |> log_in_user(owner)
      |> live(~p"/repos/#{repo.slug}/upload")

    lv
  end

  test "the idle page offers a drag-and-drop zone with the reticle watermark", ctx do
    {:ok, _lv, html} =
      ctx.conn
      |> log_in_user(ctx.owner)
      |> live(~p"/repos/#{ctx.repo.slug}/upload")

    # docs/DESIGN_UI.md — Upload: dashed hairline drop zone, reticle
    # watermark; the hook wrapper stays mounted across phases.
    assert html =~ "data-drop-zone"
    assert html =~ "border-dashed"
    assert html =~ ~r|data-drop-zone.*<svg|s
    assert html =~ ~s(phx-hook="DirectUpload")
    assert html =~ ~s(aria-label="Breadcrumb")
  end

  test "drives the full preview-and-confirm flow", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    # File selection creates a web_preview intent and starts the transfer.
    lv
    |> render_hook("select_file", %{"name" => "upload.rpm", "size" => byte_size(ctx.binary)})

    assert_push_event(lv, "start_upload", %{url: url})
    assert url =~ "X-Amz-Signature="

    intent = DarkZenith.Repo.one!(Intent)
    assert intent.mode == "web_preview"

    # The transfer phase shows the reticle spinner, not a bare progress bar.
    assert render(lv) =~ "animate-reticle-spin"

    # The browser reports the accepted version; completion queues processing.
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})
    html = render(lv)
    assert html =~ "Processing"
    # Intent states surface as badges (docs/DESIGN_UI.md — Upload).
    assert html =~ ~r|<span[^>]*badge[^>]*>\s*queued|

    # The durable worker runs the preview pass; polling picks it up.
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    html = render(lv)
    assert html =~ "Preview"
    assert html =~ "dz-fixture"
    assert html =~ "Confirm upload"

    # preview_ready badge plus a live countdown to the preview deadline.
    assert html =~ "preview ready"
    assert html =~ ~r|Preview expires in \d+:\d\d|

    send(lv.pid, :countdown)
    assert render(lv) =~ ~r|Preview expires in \d+:\d\d|

    # Confirmation queues final processing; polling lands on done.
    lv |> element("#confirm-upload") |> render_click()
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    html = render(lv)
    assert html =~ "Package uploaded."
    assert html =~ "/repos/#{ctx.repo.slug}/package-versions/#{intent.package_id}"

    assert DarkZenith.Repo.get!(Intent, intent.id).status == "succeeded"
  end

  test "an elapsed preview countdown surfaces the expiry error", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    lv |> render_hook("select_file", %{"name" => "u.rpm", "size" => byte_size(ctx.binary)})
    intent = DarkZenith.Repo.one!(Intent)
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    assert render(lv) =~ "Confirm upload"

    # Push the stored deadline into the past; the next tick reports expiry.
    import Ecto.Query, only: [from: 2]

    DarkZenith.Repo.update_all(
      from(i in Intent, where: i.id == ^intent.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
    )

    send(lv.pid, :poll)
    send(lv.pid, :countdown)
    assert render(lv) =~ "The preview expired"
  end

  test "cancel from the preview releases the upload", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    lv |> render_hook("select_file", %{"name" => "u.rpm", "size" => byte_size(ctx.binary)})
    intent = DarkZenith.Repo.one!(Intent)
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    assert render(lv) =~ "Confirm upload"

    lv |> element("#cancel-upload") |> render_click()
    assert DarkZenith.Repo.get!(Intent, intent.id).status == "canceled"
  end

  test "a processing failure explains the sanitized reason", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    lv |> render_hook("select_file", %{"name" => "u.rpm", "size" => byte_size(ctx.binary)})
    intent = DarkZenith.Repo.one!(Intent)
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})

    fail_intent!(intent.id, "validation_failed", "malformed_header_value")
    send(lv.pid, :poll)

    html = render(lv)
    assert html =~ "A header tag has an unexpected physical type."
    assert html =~ "malformed_header_value"
  end

  test "a processing failure with no reason falls back to the bare code", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    lv |> render_hook("select_file", %{"name" => "u.rpm", "size" => byte_size(ctx.binary)})
    intent = DarkZenith.Repo.one!(Intent)
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})

    fail_intent!(intent.id, "storage_unavailable", nil)
    send(lv.pid, :poll)

    assert render(lv) =~ "Processing failed: storage_unavailable."
  end

  defp fail_intent!(intent_id, code, detail) do
    import Ecto.Query, only: [from: 2]

    DarkZenith.Repo.update_all(
      from(i in Intent, where: i.id == ^intent_id),
      set: [
        status: "failed",
        reservation_id: nil,
        completed_at: DateTime.utc_now(:second),
        next_attempt_at: nil,
        lease_token: nil,
        lease_expires_at: nil,
        expires_at: nil,
        upload_url_expires_at: nil,
        last_error_code: code,
        last_error_detail: detail
      ]
    )
  end

  test "a failed transfer surfaces an error after refresh is refused", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)
    lv |> render_hook("select_file", %{"name" => "u.rpm", "size" => 100})

    # The URL is still valid, so refresh conflicts and the error shows.
    html = lv |> render_hook("upload_failed", %{"status" => 403})
    assert html =~ "direct transfer failed"
  end

  test "oversized files surface a friendly error", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    html =
      lv |> render_hook("select_file", %{"name" => "big.rpm", "size" => 5_368_709_121})

    assert html =~ "exceeds the maximum upload size"
  end

  test "non-managers get the standard 404", ctx do
    stranger = user_fixture()

    assert_error_sent 404, fn ->
      ctx.conn
      |> log_in_user(stranger)
      |> get(~p"/repos/#{ctx.repo.slug}/upload")
    end
  end
end
