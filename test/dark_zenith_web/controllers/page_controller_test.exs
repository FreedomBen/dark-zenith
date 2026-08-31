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
end
