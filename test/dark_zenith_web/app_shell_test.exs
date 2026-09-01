defmodule DarkZenithWeb.AppShellTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures

  @moduledoc """
  Guards the app shell specified in docs/DESIGN_UI.md (App shell): the top nav
  with its active-link rule, account dropdown, and mobile menu, plus the
  Layouts.app width system as adopted by representative pages.
  """

  defp header(conn, path) do
    html = conn |> get(path) |> html_response(200)
    [header] = Regex.run(~r|<header.*</header>|s, html)
    header
  end

  describe "top nav" do
    test "shows the Repositories link, inactive away from /repos", %{conn: conn} do
      header = header(conn, ~p"/")

      assert header =~ ~s(href="/repos")
      refute header =~ ~s(aria-current="page")
    end

    test "marks Repositories active under /repos", %{conn: conn} do
      assert header(conn, ~p"/repos") =~ ~s(aria-current="page")
    end

    test "signed out: Log in plus Register while registration is enabled", %{conn: conn} do
      header = header(conn, ~p"/")

      assert header =~ "Log in"
      assert header =~ "Register"
    end

    test "signed in: account dropdown with Settings and Log out, no Admin for non-admins",
         %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      header = header(conn, ~p"/")

      assert header =~ "<details"
      assert header =~ "Settings"
      assert header =~ "Log out"
      refute header =~ ~s(href="/admin")
    end

    test "signed in: the dropdown trigger shows the truncated account email", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      header = header(conn, ~p"/")

      summaries = Regex.scan(~r|<summary.*?</summary>|s, header)

      assert Enum.any?(summaries, fn [summary] ->
               summary =~ user.email and summary =~ "truncate"
             end)
    end

    test "admins see the Admin item", %{conn: conn} do
      admin = admin_fixture()
      assert header(log_in_user(conn, admin), ~p"/") =~ ~s(href="/admin")
    end

    test "mobile menu lists Repositories, account items, and the theme toggle", %{conn: conn} do
      header = header(conn, ~p"/")

      [menu] = Regex.run(~r|<details class="[^"]*sm:hidden[^"]*".*?</details>|s, header)
      assert menu =~ ~s(href="/repos")
      assert menu =~ "Log in"
      assert menu =~ "data-phx-theme"
    end

    test "a skip-to-content link precedes the nav and its target exists", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      [before_header] = Regex.run(~r|<body.*?<header|s, html)
      assert before_header =~ ~s(href="#main-content")
      assert before_header =~ "Skip to content"
      assert html =~ ~s(id="main-content")
    end

    test "renders the global package search field submitting to /search", %{conn: conn} do
      header = header(conn, ~p"/")

      assert header =~ ~s(action="/search")
      assert header =~ ~s(placeholder="Search packages…")
      assert header =~ "data-global-search"
      # Compact input on md+ plus the collapsed icon button below md.
      assert header =~ "w-64"
      assert header =~ ~s(aria-label="Search packages")
    end
  end

  describe "layout widths (docs/DESIGN_UI.md — Layout system)" do
    test "repo list uses the data width", %{conn: conn} do
      assert conn |> get(~p"/repos") |> html_response(200) =~ "max-w-7xl"
    end

    test "login uses the narrow width", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> html_response(200) =~ "max-w-md"
    end

    test "user settings uses the prose width", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert conn |> get(~p"/users/settings") |> html_response(200) =~ "max-w-3xl"
    end
  end
end
