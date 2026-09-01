defmodule DarkZenithWeb.SearchLiveTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures

  defp insert_package!(repository, overrides) do
    insert_package_from_rpm!(
      repository,
      DarkZenith.RpmFixtures.minimal_binary(),
      Map.new(overrides)
    )
  end

  describe "prompt and validation states" do
    test "a blank or absent q renders a prompt rather than results or an error", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/search")
      assert html =~ "Search for packages by name or summary"
      refute html =~ "No repositories or packages match"
      refute html =~ "limited to 256 characters"

      {:ok, _lv, html} = live(build_conn(), "/search?q=%20%20")
      assert html =~ "Search for packages by name or summary"
    end

    test "an over-long q renders the validation error", %{conn: conn} do
      q = String.duplicate("a", 257)

      {:ok, _lv, html} = live(conn, ~p"/search?#{[q: q]}")
      assert html =~ "limited to 256 characters"
      refute html =~ "No repositories or packages match"
    end

    test "the query form is submit-driven, never per-keystroke", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/search")

      assert [form] = Regex.run(~r|<form id="search-form"[^>]*>|, html)
      assert form =~ ~s(phx-submit="search")
      refute form =~ "phx-change"
    end
  end

  describe "results" do
    test "renders the repository group before the package group with links", %{conn: conn} do
      owner = user_fixture()
      repository = repository_fixture(owner, %{slug: "web-hit-repo", is_public: true})
      package = insert_package!(repository, name: "web-hit-pkg", summary: "s")

      {:ok, lv, html} = live(conn, ~p"/search?q=web-hit")

      repo_group = :binary.match(html, "search-repositories") |> elem(0)
      package_group = :binary.match(html, "search-packages") |> elem(0)
      assert repo_group < package_group

      assert has_element?(lv, ~s{#search-repositories a[href="/repos/web-hit-repo"]})

      assert has_element?(
               lv,
               ~s{#search-packages a[href="/repos/web-hit-repo/package-versions/#{package.id}"]}
             )

      assert has_element?(lv, ~s{#search-packages a[href="/repos/web-hit-repo"]})
    end

    test "the repository group caps at 20 rows and reports the total", %{conn: conn} do
      owner = user_fixture()

      for i <- 0..20 do
        repository_fixture(owner, %{
          slug: "cap-#{String.pad_leading("#{i}", 2, "0")}",
          is_public: true
        })
      end

      {:ok, lv, html} = live(conn, ~p"/search?q=cap-")

      assert html =~ "first 20 of 21 matching repositories"
      assert has_element?(lv, ~s{#search-repositories a[href="/repos/cap-19"]})
      refute has_element?(lv, ~s{#search-repositories a[href="/repos/cap-20"]})
    end

    test "the package group paginates 50 per page with the page in the URL", %{conn: conn} do
      owner = user_fixture()
      repository = repository_fixture(owner, %{is_public: true})

      for i <- 0..50 do
        insert_package!(repository,
          name: "pg-#{String.pad_leading("#{i}", 3, "0")}",
          summary: "s"
        )
      end

      {:ok, lv, html} = live(conn, ~p"/search?q=pg-")

      assert html =~ "page 1 of 2"
      assert html =~ "pg-000"
      refute html =~ "pg-050"

      lv |> element("button", "Next") |> render_click()
      assert_patch(lv, ~p"/search?q=pg-&page=2")
      html = render(lv)
      assert html =~ "pg-050"
      assert html =~ "page 2 of 2"

      # The paged URL is directly addressable.
      {:ok, _lv, html} = live(build_conn(), ~p"/search?q=pg-&page=2")
      assert html =~ "pg-050"
    end

    test "an empty result set renders the standard empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/search?q=nothing-matches-this")
      assert html =~ "No repositories or packages match"
    end

    test "a query submit patches the URL and executes the search", %{conn: conn} do
      owner = user_fixture()
      repository = repository_fixture(owner, %{slug: "submit-hit", is_public: true})
      _package = insert_package!(repository, name: "submit-hit-pkg", summary: "s")

      {:ok, lv, _html} = live(conn, ~p"/search")

      lv |> form("#search-form", %{"q" => "submit-hit"}) |> render_submit()
      assert_patch(lv, ~p"/search?q=submit-hit")
      assert has_element?(lv, ~s{#search-repositories a[href="/repos/submit-hit"]})

      # A blank submit returns to the prompt.
      lv |> form("#search-form", %{"q" => "   "}) |> render_submit()
      assert_patch(lv, ~p"/search")
      assert render(lv) =~ "Search for packages by name or summary"
    end
  end

  describe "visibility" do
    setup do
      owner = user_fixture()
      public_repo = repository_fixture(owner, %{slug: "dz-web-vis-pub", is_public: true})
      private_repo = repository_fixture(owner, %{slug: "dz-web-vis-priv", is_public: false})

      %{
        owner: owner,
        public_repo: public_repo,
        private_repo: private_repo,
        public_package: insert_package!(public_repo, name: "dz-web-vis-pub-pkg", summary: "s"),
        private_package: insert_package!(private_repo, name: "dz-web-vis-priv-pkg", summary: "s")
      }
    end

    defp search_html(conn, user) do
      conn = if user, do: log_in_user(conn, user), else: conn
      {:ok, _lv, html} = live(conn, ~p"/search?q=dz-web-vis")
      html
    end

    test "anonymous requesters see public results only", %{conn: conn} do
      html = search_html(conn, nil)
      assert html =~ "dz-web-vis-pub-pkg"
      assert html =~ "/repos/dz-web-vis-pub"
      refute html =~ "dz-web-vis-priv"
    end

    test "unrelated users see public results only", %{conn: conn} do
      html = search_html(conn, user_fixture())
      assert html =~ "dz-web-vis-pub-pkg"
      refute html =~ "dz-web-vis-priv"
    end

    test "owners additionally see their private results", %{conn: conn, owner: owner} do
      html = search_html(conn, owner)
      assert html =~ "dz-web-vis-pub-pkg"
      assert html =~ "dz-web-vis-priv-pkg"
    end

    test "collaborators additionally see collaborated private results", ctx do
      collaborator = user_fixture()
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(ctx.private_repo, collaborator)

      html = search_html(ctx.conn, collaborator)
      assert html =~ "dz-web-vis-priv-pkg"
    end

    test "admins see all results", %{conn: conn} do
      html = search_html(conn, admin_fixture())
      assert html =~ "dz-web-vis-priv-pkg"
    end
  end
end
