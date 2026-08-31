defmodule DarkZenithWeb.UserLive.LoginTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Forgot your password?"
      assert html =~ "Resend confirmation email"
    end

    test "does not render the Phoenix scaffold navbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "phoenixframework.org"
      refute html =~ "Get Started"
      refute html =~ "logo.svg"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{
            email: user.email,
            password: valid_user_password(),
            remember_me: true
          }
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{email: "test@email.com", password: "123456", remember_me: true}
        )

      conn = submit_form(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (viewing the login page while logged in)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "still renders the login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Log in"
    end
  end
end
