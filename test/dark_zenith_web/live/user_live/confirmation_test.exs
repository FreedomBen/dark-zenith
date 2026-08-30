defmodule DarkZenithWeb.UserLive.ConfirmationTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Repo

  setup do
    %{user: unconfirmed_user_fixture()}
  end

  describe "confirm user" do
    test "renders confirmation page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/confirm/some-token")
      assert html =~ "Confirm my account"
    end

    test "confirms the given token once", %{conn: conn, user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      result =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert {:ok, conn} = result

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "User confirmed successfully"

      assert Accounts.get_user!(user.id).confirmed_at
      # The user is not logged in by confirmation.
      refute get_session(conn, :user_token)
      refute Repo.get_by(Accounts.UserToken, user_id: user.id)

      # When not logged in, repeating the confirmation shows an error.
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      result =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert {:ok, conn} = result

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "User confirmation link is invalid or it has expired"

      # When logged in as the confirmed user, a stale link redirects silently.
      conn =
        build_conn()
        |> log_in_user(Accounts.get_user!(user.id))

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      result =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert {:ok, conn} = result
      refute Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "does not confirm email with invalid token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/invalid-token")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "User confirmation link is invalid or it has expired"

      refute Accounts.get_user!(user.id).confirmed_at
    end
  end
end
