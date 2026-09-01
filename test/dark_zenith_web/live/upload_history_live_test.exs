defmodule DarkZenithWeb.UploadHistoryLiveTest do
  @moduledoc """
  The repository detail page's Upload History section (DESIGN.md:
  Repository Detail — Upload History; docs/DESIGN_UI.md — U9).
  """
  use DarkZenithWeb.ConnCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.B2StubHelpers
  import DarkZenith.CollaboratorsFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures
  import Ecto.Query, only: [from: 2]

  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.{Intent, Record, Records}
  alias DarkZenith.Workers.UploadProcessing

  setup do
    owner = user_fixture()
    admin = admin_fixture()
    %{owner: owner, admin: admin, repo: repository_fixture(owner, %{is_public: true})}
  end

  defp create!(user, repo, attrs \\ %{}) do
    {:ok, intent, _} =
      Uploads.create_intent(
        user,
        repo,
        Map.merge(%{filename: "pkg.rpm", size: 1000, mode: "api"}, attrs)
      )

    intent
  end

  defp record_for(intent), do: Records.get_by_intent(intent.id)

  defp mount_as(conn, user, repo, query \\ "") do
    {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/repos/#{repo.slug}" <> query)
    {lv, html}
  end

  defp section(lv), do: lv |> element("#upload-history") |> render()

  defp fail!(intent, code, detail) do
    {:ok, _} =
      DarkZenith.Repo.transact(fn ->
        Uploads.terminalize!(intent, "failed", code, detail)
        {:ok, :ok}
      end)
  end

  defp succeed!(owner, repo) do
    binary = v4_binary()
    intent = create!(owner, repo, %{filename: "upload.rpm", size: byte_size(binary)})
    stub_pipeline(intent, binary)
    {:ok, queued} = Uploads.complete_intent(owner, intent, 1, "4_zstaged")
    assert :ok = perform_job(UploadProcessing, %{"intent_id" => queued.id})
    intent
  end

  describe "visibility" do
    test "the section is omitted entirely while the repository has no records", ctx do
      {_lv, html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      refute html =~ "Upload History"
      refute html =~ ~s(id="upload-history")
    end

    test "only the owner or an admin sees it", ctx do
      private = repository_fixture(ctx.owner, %{is_public: false})
      create!(ctx.owner, ctx.repo)
      create!(ctx.owner, private)

      {_lv, html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      assert html =~ ~s(id="upload-history")

      {_lv, html} = mount_as(ctx.conn, ctx.admin, ctx.repo)
      assert html =~ ~s(id="upload-history")

      collaborator = user_fixture()
      collaborator_row_fixture(private, collaborator)
      {_lv, html} = mount_as(ctx.conn, collaborator, private)
      refute html =~ "Upload History"

      {:ok, _lv, html} = live(ctx.conn, ~p"/repos/#{ctx.repo.slug}")
      refute html =~ "Upload History"
      refute html =~ ctx.owner.email
    end
  end

  describe "rows" do
    test "show filename, initiator, source, size, status, and times", ctx do
      own = create!(ctx.owner, ctx.repo, %{filename: "mine.rpm", size: 1000})

      theirs =
        create!(ctx.admin, ctx.repo, %{filename: "admin.rpm", size: 2048, mode: "web_preview"})

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      html = section(lv)

      assert html =~ "mine.rpm"
      assert html =~ "admin.rpm"
      assert html =~ ctx.owner.email
      assert html =~ ctx.admin.email
      assert html =~ "1000 B"
      assert html =~ "2.0 KiB"
      assert html =~ ~r|>\s*API\s*<|
      assert html =~ ~r|>\s*web\s*<|
      assert html =~ ~r|<span[^>]*badge[^>]*>\s*awaiting upload|
      assert html =~ ~r|\d{4}-\d{2}-\d{2} \d{2}:\d{2}|

      # The viewer's own row is labeled as theirs; the admin's is not.
      own_row = lv |> element("#upload-record-#{record_for(own).id}") |> render()
      assert own_row =~ ">you<"
      their_row = lv |> element("#upload-record-#{record_for(theirs).id}") |> render()
      refute their_row =~ ">you<"

      # No capability, staging, lease, or preview material reaches the page.
      refute html =~ "staging/uploads/"
      refute html =~ "X-Amz-Signature"
      refute html =~ own.user_id
    end

    test "a succeeded row shows its NEVRA linked to the package version page", ctx do
      intent = succeed!(ctx.owner, ctx.repo)
      record = record_for(intent)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      row = lv |> element("#upload-record-#{record.id}") |> render()

      assert row =~ ~r|<span[^>]*badge[^>]*>\s*succeeded|
      assert row =~ record.nevra
      assert row =~ ~s(href="/repos/#{ctx.repo.slug}/package-versions/#{intent.package_id}")
      # The stored size of the resulting package, not the declared size.
      assert row =~ "#{Float.round(byte_size(v4_binary()) / 1024, 1)} KiB"
    end

    test "a failed row shows the sanitized code and reason", ctx do
      with_reason = create!(ctx.owner, ctx.repo, %{filename: "bad.rpm"})
      fail!(with_reason, "validation_failed", "truncated")
      bare = create!(ctx.owner, ctx.repo, %{filename: "infra.rpm"})
      fail!(bare, "storage_unavailable", nil)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)

      row = lv |> element("#upload-record-#{record_for(with_reason).id}") |> render()
      assert row =~ ~r|<span[^>]*badge[^>]*>\s*failed|
      assert row =~ "validation_failed"
      assert row =~ "truncated"

      row = lv |> element("#upload-record-#{record_for(bare).id}") |> render()
      assert row =~ "storage_unavailable"
      refute row =~ "·"
    end

    test "expired and canceled rows are muted and an orphan reads Unknown", ctx do
      expired = create!(ctx.owner, ctx.repo)
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

      DarkZenith.Repo.update_all(from(i in Intent, where: i.id == ^expired.id),
        set: [expires_at: past]
      )

      Uploads.expire_overdue()

      canceled = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, canceled)

      orphan = create!(ctx.owner, ctx.repo, %{filename: "orphan.rpm"})
      DarkZenith.Repo.delete_all(from(i in Intent, where: i.id == ^orphan.id))

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)

      row = lv |> element("#upload-record-#{record_for(expired).id}") |> render()
      assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*expired|

      row = lv |> element("#upload-record-#{record_for(canceled).id}") |> render()
      assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*canceled|

      # Awaiting reconciliation: not progress, no spinner, no cancel, no link.
      orphan_record = record_for(orphan)
      row = lv |> element("#upload-record-#{orphan_record.id}") |> render()
      assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*Unknown|
      refute row =~ "animate-reticle-spin"
      refute row =~ "cancel-upload-#{orphan_record.id}"
      refute row =~ "/upload?intent="
    end

    test "the viewer's own in-flight rows link to the upload page; others' do not", ctx do
      own = create!(ctx.owner, ctx.repo)
      theirs = create!(ctx.admin, ctx.repo)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)

      own_row = lv |> element("#upload-record-#{record_for(own).id}") |> render()
      assert own_row =~ ~s(href="/repos/#{ctx.repo.slug}/upload?intent=#{own.id}")

      their_row = lv |> element("#upload-record-#{record_for(theirs).id}") |> render()
      refute their_row =~ "/upload?intent="
    end

    test "cancellation is offered only on the viewer's own cancelable rows", ctx do
      own = create!(ctx.owner, ctx.repo)
      theirs = create!(ctx.admin, ctx.repo)
      done = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, done)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)

      assert has_element?(lv, "#cancel-upload-#{record_for(own).id}")
      refute has_element?(lv, "#cancel-upload-#{record_for(theirs).id}")
      refute has_element?(lv, "#cancel-upload-#{record_for(done).id}")

      lv |> element("#cancel-upload-#{record_for(own).id}") |> render_click()

      assert DarkZenith.Repo.get!(Intent, own.id).status == "canceled"
      assert record_for(own).outcome == "canceled"
      assert render(lv) =~ "Upload canceled."
      refute has_element?(lv, "#cancel-upload-#{record_for(own).id}")

      # A crafted event naming another user's intent changes nothing.
      render_click(lv, "cancel_upload", %{"id" => theirs.id})
      assert DarkZenith.Repo.get!(Intent, theirs.id).status == "awaiting_upload"
      assert render(lv) =~ "could not be canceled"
    end
  end

  describe "header, filter, and pages" do
    test "the pill states the in-flight count and links to the in_flight filter", ctx do
      create!(ctx.owner, ctx.repo)
      create!(ctx.admin, ctx.repo)
      done = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, done)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)

      pill = lv |> element("#in-flight-count") |> render()
      assert pill =~ "2 in flight"
      assert pill =~ ~s(href="/repos/#{ctx.repo.slug}?outcome=in_flight")

      lv |> element("#in-flight-count") |> render_click()
      assert_patch(lv, ~p"/repos/#{ctx.repo.slug}?outcome=in_flight")

      refute has_element?(lv, "#upload-record-#{record_for(done).id}")
      assert lv |> element("#outcome-filter a[aria-current]") |> render() =~ "In flight"
    end

    test "the outcome filter is held in the URL as the REST parameter", ctx do
      failed = create!(ctx.owner, ctx.repo)
      fail!(failed, "validation_failed", nil)
      live = create!(ctx.owner, ctx.repo)
      canceled = create!(ctx.owner, ctx.repo)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, canceled)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo, "?outcome=failed")
      assert has_element?(lv, "#upload-record-#{record_for(failed).id}")
      refute has_element?(lv, "#upload-record-#{record_for(live).id}")
      assert lv |> element("#outcome-filter a[aria-current]") |> render() =~ "Failed"

      # A comma-separated subset still filters but selects no segment.
      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo, "?outcome=failed,canceled")
      assert has_element?(lv, "#upload-record-#{record_for(failed).id}")
      assert has_element?(lv, "#upload-record-#{record_for(canceled).id}")
      refute has_element?(lv, "#upload-record-#{record_for(live).id}")
      refute has_element?(lv, "#outcome-filter a[aria-current]")

      # An unparseable value falls back to the unfiltered list.
      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo, "?outcome=bogus")
      assert has_element?(lv, "#upload-record-#{record_for(live).id}")
      assert lv |> element("#outcome-filter a[aria-current]") |> render() =~ "All"

      # Segments are patch links, so the filter is shareable.
      lv |> element("#outcome-filter a", "Canceled") |> render_click()
      assert_patch(lv, ~p"/repos/#{ctx.repo.slug}?outcome=canceled")
      refute has_element?(lv, "#upload-record-#{record_for(live).id}")

      lv |> element("#outcome-filter a", "All") |> render_click()
      assert_patch(lv, ~p"/repos/#{ctx.repo.slug}")
      assert has_element?(lv, "#upload-record-#{record_for(live).id}")
    end

    test "a filter with no matches keeps the section with an empty state", ctx do
      create!(ctx.owner, ctx.repo)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo, "?outcome=succeeded")
      assert section(lv) =~ "No uploads match this filter."
      assert has_element?(lv, "#in-flight-count")
    end

    test "paginates at 25 per page with the page in the URL", ctx do
      intents = for n <- 1..26, do: create!(ctx.owner, ctx.repo, %{filename: "f#{n}.rpm"})
      base = DateTime.utc_now(:second)

      for {intent, n} <- Enum.with_index(intents) do
        DarkZenith.Repo.update_all(
          from(r in Record, where: r.intent_id == ^intent.id),
          set: [started_at: DateTime.add(base, n - 100, :second)]
        )
      end

      oldest = List.first(intents)
      newest = List.last(intents)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      assert has_element?(lv, "#upload-record-#{record_for(newest).id}")
      refute has_element?(lv, "#upload-record-#{record_for(oldest).id}")
      assert lv |> element("#upload-pagination") |> render() =~ "page 1 of 2"

      lv |> element("#upload-pagination a", "Next") |> render_click()
      assert_patch(lv, ~p"/repos/#{ctx.repo.slug}?page=2")
      assert has_element?(lv, "#upload-record-#{record_for(oldest).id}")
      refute has_element?(lv, "#upload-record-#{record_for(newest).id}")
      assert lv |> element("#upload-pagination") |> render() =~ "page 2 of 2"

      # The page survives beside a filter, and page one drops out of the URL.
      lv |> element("#upload-pagination a", "Previous") |> render_click()
      assert_patch(lv, ~p"/repos/#{ctx.repo.slug}")

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo, "?outcome=in_flight&page=2")
      assert has_element?(lv, "#upload-record-#{record_for(oldest).id}")
    end
  end

  describe "refresh" do
    defp refresh_ref(lv), do: :sys.get_state(lv.pid).socket.assigns.upload_refresh_ref

    test "the timer follows the repository-wide in-flight count", ctx do
      live = create!(ctx.owner, ctx.repo)

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      assert refresh_ref(lv)

      # The intent finishes out of band; the next tick shows the outcome.
      {:ok, _} = Uploads.cancel_intent(ctx.owner, live)
      send(lv.pid, :refresh_upload_history)

      row = lv |> element("#upload-record-#{record_for(live).id}") |> render()
      assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*canceled|
      assert lv |> element("#in-flight-count") |> render() =~ "0 in flight"

      # With nothing in flight the timer stops.
      refute refresh_ref(lv)
    end

    test "an in-flight upload past the first page keeps the timer armed", ctx do
      stuck = create!(ctx.owner, ctx.repo, %{filename: "stuck.rpm"})
      newer = for n <- 1..25, do: create!(ctx.owner, ctx.repo, %{filename: "n#{n}.rpm"})
      for intent <- newer, do: {:ok, _} = Uploads.cancel_intent(ctx.owner, intent)

      old = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      DarkZenith.Repo.update_all(from(r in Record, where: r.intent_id == ^stuck.id),
        set: [started_at: old]
      )

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      refute has_element?(lv, "#upload-record-#{record_for(stuck).id}")
      assert lv |> element("#in-flight-count") |> render() =~ "1 in flight"
      assert refresh_ref(lv)
    end

    test "an awaiting-reconciliation row holds the timer open until the sweep", ctx do
      orphan = create!(ctx.owner, ctx.repo)
      DarkZenith.Repo.delete_all(from(i in Intent, where: i.id == ^orphan.id))

      {lv, _html} = mount_as(ctx.conn, ctx.owner, ctx.repo)
      assert refresh_ref(lv)

      Uploads.reconcile_orphaned_records()
      send(lv.pid, :refresh_upload_history)

      row = lv |> element("#upload-record-#{record_for(orphan).id}") |> render()
      assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*canceled|
      refute refresh_ref(lv)
    end
  end
end
