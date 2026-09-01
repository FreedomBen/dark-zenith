defmodule DarkZenithWeb.AdminUploadsLiveTest do
  @moduledoc """
  The admin Uploads tab (DESIGN.md: Admin — Upload records;
  docs/DESIGN_UI.md — U10): the instance-wide, read-only upload-record
  view that outlives repositories, packages, and initiators.
  """
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import Ecto.Query, only: [from: 2]

  alias DarkZenith.Repositories
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.{Intent, Record, Records}

  setup %{conn: conn} do
    admin = admin_fixture()
    owner = user_fixture()
    other = user_fixture()

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      owner: owner,
      other: other,
      repo: repository_fixture(owner),
      other_repo: repository_fixture(other)
    }
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

  test "non-admins get the standard 404", ctx do
    assert_error_sent 404, fn ->
      build_conn() |> log_in_user(ctx.owner) |> get(~p"/admin/uploads")
    end
  end

  test "lists records across repositories with a linked slug column", ctx do
    mine = create!(ctx.owner, ctx.repo, %{filename: "mine.rpm"})
    theirs = create!(ctx.other, ctx.other_repo, %{filename: "theirs.rpm"})

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")

    assert lv |> element("h1") |> render() =~ "Admin"
    assert lv |> element(~s{nav a[aria-current="page"]}) |> render() =~ "Uploads"

    row = lv |> element("#upload-record-#{record_for(mine).id}") |> render()
    assert row =~ "mine.rpm"
    assert row =~ ctx.owner.email
    assert row =~ ~s(href="/repos/#{ctx.repo.slug}")
    assert row =~ ~r|<span[^>]*badge[^>]*>\s*awaiting upload|

    row = lv |> element("#upload-record-#{record_for(theirs).id}") |> render()
    assert row =~ ~s(href="/repos/#{ctx.other_repo.slug}")
  end

  test "a record whose repository is gone keeps its slug snapshot with no link", ctx do
    gone = create!(ctx.owner, ctx.repo, %{filename: "gone.rpm"})
    :ok = Repositories.delete_repository(ctx.owner, ctx.repo)

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")

    row = lv |> element("#upload-record-#{record_for(gone).id}") |> render()
    assert row =~ ctx.repo.slug
    refute row =~ ~s(href="/repos/#{ctx.repo.slug}")
    # Deleting the repository canceled the in-flight record.
    assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*canceled|

    # A revived slug is a different repository and gets no link either.
    {:ok, revived} = Repositories.create_repository(ctx.owner, %{slug: ctx.repo.slug, name: "R"})
    assert revived.id != ctx.repo.id
    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")
    row = lv |> element("#upload-record-#{record_for(gone).id}") |> render()
    refute row =~ ~s(href="/repos/#{ctx.repo.slug}")
  end

  test "filters by repository, normalized initiator, and outcome, all held in the URL", ctx do
    mine = create!(ctx.owner, ctx.repo)
    theirs = create!(ctx.other, ctx.other_repo)
    {:ok, _} = Uploads.cancel_intent(ctx.other, theirs)

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")

    lv
    |> form("#upload-filters")
    |> render_change(%{"repository" => ctx.repo.slug, "initiator" => ""})

    assert_patch(lv, ~p"/admin/uploads?repository=#{ctx.repo.slug}")
    assert has_element?(lv, "#upload-record-#{record_for(mine).id}")
    refute has_element?(lv, "#upload-record-#{record_for(theirs).id}")

    # The initiator email is normalized like every other email input.
    shouted = "  " <> String.upcase(ctx.other.email) <> " "
    lv |> form("#upload-filters") |> render_change(%{"repository" => "", "initiator" => shouted})
    assert_patch(lv, ~p"/admin/uploads?initiator=#{shouted}")
    assert has_element?(lv, "#upload-record-#{record_for(theirs).id}")
    refute has_element?(lv, "#upload-record-#{record_for(mine).id}")

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads?outcome=canceled")
    assert has_element?(lv, "#upload-record-#{record_for(theirs).id}")
    refute has_element?(lv, "#upload-record-#{record_for(mine).id}")
    assert lv |> element("#outcome-filter a[aria-current]") |> render() =~ "Canceled"

    # The outcome segments preserve the text filters.
    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads?repository=#{ctx.repo.slug}")
    lv |> element("#outcome-filter a", "In flight") |> render_click()
    assert_patch(lv, ~p"/admin/uploads?outcome=in_flight&repository=#{ctx.repo.slug}")
    assert has_element?(lv, "#upload-record-#{record_for(mine).id}")

    {:ok, _lv, html} = live(ctx.conn, ~p"/admin/uploads?repository=no-such-slug")
    assert html =~ "No upload records match the filters."
  end

  test "in-flight rows show live status or Unknown, with no actions and no refresh", ctx do
    live_intent = create!(ctx.admin, ctx.repo)
    orphan = create!(ctx.owner, ctx.repo)
    DarkZenith.Repo.delete_all(from(i in Intent, where: i.id == ^orphan.id))

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")

    row = lv |> element("#upload-record-#{record_for(live_intent).id}") |> render()
    assert row =~ ~r|<span[^>]*badge[^>]*>\s*awaiting upload|
    # Even the admin's own live intent gets no action here: the view is read-only.
    refute row =~ "cancel-upload-"
    refute row =~ "/upload?intent="

    row = lv |> element("#upload-record-#{record_for(orphan).id}") |> render()
    assert row =~ ~r|<span[^>]*badge-ghost[^>]*>\s*Unknown|

    refute has_element?(lv, "#in-flight-count")
    refute Map.has_key?(:sys.get_state(lv.pid).socket.assigns, :upload_refresh_ref)
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

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/uploads")
    refute has_element?(lv, "#upload-record-#{record_for(oldest).id}")
    assert lv |> element("#upload-pagination") |> render() =~ "page 1 of 2"

    lv |> element("#upload-pagination a", "Next") |> render_click()
    assert_patch(lv, ~p"/admin/uploads?page=2")
    assert has_element?(lv, "#upload-record-#{record_for(oldest).id}")
  end
end
