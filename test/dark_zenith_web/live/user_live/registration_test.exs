defmodule DarkZenithWeb.UserLive.RegistrationTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, "/users/settings")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces", "password" => "short"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "should be at least 12 character"
    end
  end

  describe "register user" do
    test "creates an unconfirmed account and delivers confirmation instructions", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "please access it to confirm your account"

      user = Accounts.get_user_by_email(email)
      assert user
      assert is_nil(user.confirmed_at)

      # The user cannot log in until confirmation.
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user(email, valid_user_password())

      # A confirmation token was created.
      assert DarkZenith.Repo.get_by(Accounts.UserToken, user_id: user.id, context: "confirm")
    end

    test "renders errors for duplicated email", %{conn: conn} do
      %{email: email} = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => email, "password" => valid_user_password()}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration links" do
    test "the login page links to registration when enabled", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ ~p"/users/register"
    end
  end
end
