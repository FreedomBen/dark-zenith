defmodule DarkZenithWeb.PackageLiveTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  setup do
    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: true})
    %{owner: owner, repo: repo}
  end

  describe "repository detail package table" do
    test "lists packages with EVR ordering and search", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_binary())

      for version <- ["1.0", "10.0"] do
        insert_package_from_rpm!(repo, minimal_binary(), %{
          name: "multi",
          version: version,
          release: "1",
          epoch: 0
        })
      end

      {:ok, lv, html} = live(conn, ~p"/repos/#{repo.slug}")

      assert html =~ "dz-fixture"
      assert html =~ "2:1.2.3-4"

      # EVR-descending within a name: 10.0 above 1.0.
      assert [i10, i1] = Regex.scan(~r/multi.*?(10\.0|1\.0)-1/s, html) |> Enum.map(&List.last/1)
      assert {i10, i1} == {"10.0", "1.0"}

      html = lv |> render_change("search_packages", %{"q" => "dz-fix"})
      assert html =~ "dz-fixture"
      refute html =~ "multi"
    end

    test "headers sort the table as real buttons", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_binary())

      insert_package_from_rpm!(repo, minimal_binary(), %{
        name: "aaa-first",
        version: "1.0",
        release: "1",
        epoch: 0
      })

      {:ok, lv, html} = live(conn, ~p"/repos/#{repo.slug}")

      # Sortable headers are buttons carrying the next sort
      # (docs/DESIGN_UI.md — Tables).
      assert html =~ ~s(phx-value-sort="name")
      assert html =~ ~s(phx-value-sort="version")
      assert html =~ ~s(phx-value-sort="arch")
      assert html =~ ~s(phx-value-sort="inserted_at")

      html = lv |> element("th button", "Name") |> render_click()
      assert html =~ ~s(aria-sort="ascending")
      # The active ascending header now offers the descending toggle.
      assert html =~ ~s(phx-value-sort="-name")

      html = lv |> element("th button", "Name") |> render_click()
      assert html =~ ~s(aria-sort="descending")

      # Descending by name puts dz-fixture before aaa-first.
      assert [pos_dz, pos_a] =
               [
                 :binary.match(html, "dz-fixture") |> elem(0),
                 :binary.match(html, "aaa-first") |> elem(0)
               ]

      assert pos_dz < pos_a

      # An out-of-vocabulary sort value is refused server-side.
      assert render_click(lv, "sort_packages", %{"sort" => "id; DROP"}) =~ "dz-fixture"
    end
  end

  describe "package detail page" do
    test "shows builds and install instructions", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_binary())

      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}/packages/dz-fixture")

      assert html =~ "dnf install dz-fixture"
      refute html =~ "dnf download --source"
      assert html =~ "2:1.2.3-4"
      assert html =~ "noarch"

      # Title block: breadcrumb trail and a mono data title
      # (docs/DESIGN_UI.md — Breadcrumbs, Package detail).
      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ ~r|<h1[^>]*>\s*<span[^>]*"font-mono"[^>]*>dz-fixture</span>|
    end

    test "source-only names show only the source command", %{conn: conn, repo: repo} do
      insert_package_from_rpm!(repo, v4_source_binary())

      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}/packages/dz-fixture")

      refute html =~ "dnf install dz-fixture"
      assert html =~ "dnf download --source dz-fixture"
    end

    test "unknown names 404", %{conn: conn, repo: repo} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/repos/#{repo.slug}/packages/absent")
      end
    end
  end

  describe "package version page" do
    setup %{repo: repo} do
      %{package: insert_package_from_rpm!(repo, v4_binary())}
    end

    test "shows metadata, counts, and the download link", %{
      conn: conn,
      repo: repo,
      package: package
    } do
      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}/package-versions/#{package.id}")

      assert html =~ "dz-fixture 2:1.2.3-4"
      assert html =~ "requires (6)"
      assert html =~ "files (3)"
      assert html =~ "/repos/#{repo.slug}/packages/#{package.id}/dz-fixture-1.2.3-4.noarch.rpm"
      assert html =~ "Fixture package for the Dark Zenith pure-Elixir RPM parser."
    end

    test "tabs lazy-load their collections", %{conn: conn, repo: repo, package: package} do
      {:ok, lv, html} = live(conn, ~p"/repos/#{repo.slug}/package-versions/#{package.id}")

      refute html =~ "dz-pre-tool"

      html = lv |> element("#tab-requires") |> render_click()
      assert html =~ "dz-pre-tool"
      assert html =~ "dz-lib &gt;= 0:1.0"
      assert html =~ ~r|id="tab-requires"[^>]*aria-selected="true"|

      html = lv |> element("#tab-files") |> render_click()
      assert html =~ "/usr/bin/dz-fixture"
    end

    test "private repositories mask the page", %{conn: conn, owner: owner} do
      private = repository_fixture(owner, %{is_public: false})
      package = insert_package_from_rpm!(private, minimal_binary())
      stranger = user_fixture()

      assert_error_sent 404, fn ->
        conn
        |> log_in_user(stranger)
        |> get(~p"/repos/#{private.slug}/package-versions/#{package.id}")
      end
    end
  end
end

defmodule DarkZenithWeb.PackageEscapingTest do
  # DESIGN.md (Web Interface): RPM-derived strings render as plain text with
  # HTML escaping; `url` is the only RPM-derived hyperlink.
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  @hostile ~s|<script>alert("dz")</script>|

  setup do
    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: true})

    package =
      insert_package_from_rpm!(repo, minimal_binary(), %{
        summary: @hostile,
        description: ~s|<img src=x onerror="alert('dz')">|,
        license: @hostile,
        rpm_vendor: @hostile,
        url: "https://example.com/upstream"
      })

    %{repo: repo, package: package}
  end

  test "package pages escape RPM-derived strings", %{conn: conn, repo: repo, package: package} do
    for path <- [
          ~p"/repos/#{repo.slug}",
          ~p"/repos/#{repo.slug}/packages/#{package.name}",
          ~p"/repos/#{repo.slug}/package-versions/#{package.id}"
        ] do
      {:ok, _lv, html} = live(conn, path)
      refute html =~ "<script>alert", "unescaped script tag rendered at #{path}"
      refute html =~ "<img src=x", "unescaped attribute injection rendered at #{path}"
    end

    {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}/package-versions/#{package.id}")
    assert html =~ "&lt;script&gt;alert"
    assert html =~ ~s|href="https://example.com/upstream"|
  end

  test "only url renders as a hyperlink", %{conn: conn, repo: repo, package: package} do
    {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}/package-versions/#{package.id}")

    hrefs =
      Regex.scan(~r/href="([^"]+)"/, html)
      |> Enum.map(&List.last/1)
      |> Enum.filter(&String.contains?(&1, "example.com"))

    assert hrefs == ["https://example.com/upstream"]
  end
end
