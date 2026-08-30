defmodule DarkZenithWeb.UserLive.ForgotPasswordTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Repo

  describe "Forgot password page" do
    test "renders email page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password")

      assert html =~ "Forgot your password?"
      assert html =~ "Send password reset instructions"
    end
  end

  describe "Reset link" do
    setup do
      %{user: user_fixture()}
    end

    test "sends a new reset password token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert Repo.get_by!(Accounts.UserToken, user_id: user.id).context ==
               "reset_password"
    end

    test "does not send reset password token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Repo.all(Accounts.UserToken) == []
    end
  end
end
