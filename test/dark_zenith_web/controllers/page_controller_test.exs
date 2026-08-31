defmodule DarkZenithWeb.PageControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  test "GET / renders the hero with headline, sample command, and actions", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Dark Zenith"
    assert html =~ "RPM repository"
    assert html =~ ~p"/repos"

    # Star-field backdrop (night) / gradient (day) hangs off the dz-hero hook,
    # and the headline is display-face at hero scale (docs/DESIGN_UI.md).
    assert html =~ "dz-hero"
    assert [h1] = Regex.run(~r|<h1[^>]*>|, html)
    assert h1 =~ "font-display"
    assert h1 =~ "text-5xl"

    # The sample dnf command renders as a command block with a copy button.
    assert html =~ "dnf5 config-manager addrepo"
    assert html =~ ~s(aria-label="Copy to clipboard")
    assert html =~ "bg-umbra"

    # Signed-out visitors see both hero actions.
    assert html =~ "Browse repositories"
    assert html =~ "Log in"
  end

  test "GET / links the available repositories (DESIGN.md: Landing Page)", %{conn: conn} do
    import DarkZenith.AccountsFixtures
    import DarkZenith.RepositoriesFixtures

    owner = user_fixture()
    public = repository_fixture(owner, %{name: "Landing Public", is_public: true})
    _private = repository_fixture(owner, %{name: "Landing Private", is_public: false})

    html = conn |> get(~p"/") |> html_response(200)

    # Anonymous visitors see links to public repositories only.
    assert html =~ "Landing Public"
    assert html =~ ~p"/repos/#{public.slug}"
    refute html =~ "Landing Private"

    # Signed-in users also see their private repositories.
    html =
      build_conn()
      |> log_in_user(owner)
      |> get(~p"/")
      |> html_response(200)

    assert html =~ "Landing Private"
  end

  test "GET / with no repositories renders the reticle empty state", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "No repositories yet."
    assert html =~ "opacity-30"
  end

  test "the star-field asset is checked in and static", %{conn: conn} do
    svg = File.read!(Path.expand("../../../priv/static/images/starfield.svg", __DIR__))

    # Deterministic, no animation (docs/DESIGN_UI.md — Page notes).
    refute svg =~ "<animate"
    refute svg =~ "<script"
    assert svg =~ "<circle"

    # Served same-origin so the CSP's img-src 'self' admits it.
    conn = get(conn, "/images/starfield.svg")
    assert response(conn, 200)
    assert response_content_type(conn, :svg) =~ "image/svg"
  end

  test "GET / renders the theme toggle in the top menu", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "data-phx-theme"
  end

  test "GET / does not brand the page title with Phoenix Framework", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    refute html =~ "Phoenix Framework"
  end

  test "GET / preloads the core web fonts", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(rel="preload" as="font")
    assert html =~ ~s(href="/fonts/ibm-plex-sans-latin-400.woff2")
    assert html =~ ~s(href="/fonts/ibm-plex-mono-latin-400.woff2")
  end

  test "GET / loads the theme script externally with no inline scripts (CSP script-src 'self')",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    # The strict CSP blocks inline script execution, so the pre-paint theme
    # script must be external and parser-blocking (no defer).
    [theme_tag] = Regex.run(~r|<script[^>]*src="/assets/js/theme\.js"[^>]*>|, html)
    refute theme_tag =~ "defer"

    # No executable inline scripts anywhere on the page.
    assert Regex.scan(~r|<script(?![^>]*\bsrc=)[^>]*>|, html) == []

    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self';"
  end

  test "GET / includes the favicon set", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(<link rel="icon" href="/favicon.ico" sizes="any")
    assert html =~ ~s(<link rel="icon" href="/favicon.svg" type="image/svg+xml")
    assert html =~ ~s(<link rel="apple-touch-icon" href="/apple-touch-icon.png")
  end

  test "GET / brands the header with the mark and wordmark linking home", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert [brand] = Regex.run(~r|<a href="/"[^>]*>.*?</a>|s, html)
    assert brand =~ "<svg"
    assert brand =~ "DARK ZENITH"
  end

  test "GET / renders the footer with version, license, and source link", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    version = to_string(Application.spec(:dark_zenith, :vsn))
    assert [footer] = Regex.run(~r|<footer.*</footer>|s, html)
    assert footer =~ "v#{version}"
    assert footer =~ "AGPL-3.0-or-later"
    assert footer =~ ~s(href="#{DarkZenith.source_url()}")
  end

  test "theme script defaults first-time visitors to dark and stores explicit choices" do
    js = File.read!(Path.expand("../../../assets/js/theme.js", __DIR__))

    # Unforced default: dark, applied without persisting a choice.
    assert js =~ ~s[applyTheme("dark", "default")]
    # An explicit "system" choice must be stored, not expressed as key absence.
    assert js =~ ~s[localStorage.setItem("phx:theme", "system")]
  end
end
