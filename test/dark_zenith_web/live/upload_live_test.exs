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

  test "drives the full preview-and-confirm flow", ctx do
    lv = mount_upload(ctx.conn, ctx.owner, ctx.repo)

    # File selection creates a web_preview intent and starts the transfer.
    lv
    |> render_hook("select_file", %{"name" => "upload.rpm", "size" => byte_size(ctx.binary)})

    assert_push_event(lv, "start_upload", %{url: url})
    assert url =~ "X-Amz-Signature="

    intent = DarkZenith.Repo.one!(Intent)
    assert intent.mode == "web_preview"

    # The browser reports the accepted version; completion queues processing.
    stub_pipeline(intent, ctx.binary)
    lv |> render_hook("uploaded", %{"version_id" => "4_zstaged"})
    assert render(lv) =~ "Processing"

    # The durable worker runs the preview pass; polling picks it up.
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    html = render(lv)
    assert html =~ "Preview"
    assert html =~ "dz-fixture"
    assert html =~ "Confirm upload"

    # Confirmation queues final processing; polling lands on done.
    lv |> element("#confirm-upload") |> render_click()
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => intent.id})
    send(lv.pid, :poll)
    html = render(lv)
    assert html =~ "Package uploaded."
    assert html =~ "/repos/#{ctx.repo.slug}/package-versions/#{intent.package_id}"

    assert DarkZenith.Repo.get!(Intent, intent.id).status == "succeeded"
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
