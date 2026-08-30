defmodule DarkZenithWeb.UserLive.RegistrationDisabledTest do
  # Not async: temporarily flips the global registration_enabled setting.
  use DarkZenithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:dark_zenith, :registration_enabled)
    Application.put_env(:dark_zenith, :registration_enabled, false)
    on_exit(fn -> Application.put_env(:dark_zenith, :registration_enabled, previous) end)
    :ok
  end

  test "the registration route renders the standard 404 while disabled", %{conn: conn} do
    assert_error_sent 404, fn ->
      get(conn, ~p"/users/register")
    end
  end

  test "the login page renders no registration link while disabled", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    refute html =~ ~p"/users/register"
  end
end
