defmodule DarkZenithWeb.PageControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  test "GET / renders the landing page with a repositories link", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Dark Zenith"
    assert html =~ "RPM package repository"
    assert html =~ ~p"/repos"
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
