defmodule DarkZenithWeb.UserLive.ResetPasswordTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    %{token: token, user: user}
  end

  describe "Reset password page" do
    test "renders reset password with valid token", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Reset password"
    end

    test "does not render reset password with invalid token", %{conn: conn} do
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/invalid")

      assert to == %{
               flash: %{"error" => "Reset password link is invalid or it has expired."},
               to: ~p"/"
             }
    end

    test "renders errors for invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> element("#reset_password_form")
        |> render_change(
          user: %{"password" => "short", "password_confirmation" => "secret123456"}
        )

      assert result =~ "should be at least 12 character"
      assert result =~ "does not match"
    end
  end

  describe "Reset Password" do
    test "resets password once and shows the API-key completion page", %{
      conn: conn,
      token: token,
      user: user
    } do
      {:ok, {key_plaintext, _}} =
        Accounts.create_api_key(user, %{name: "survivor", scopes: ["repo:read"]})

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      html =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        )
        |> render_submit()

      # The completion page lists surviving active API keys with revoke-all.
      assert html =~ "Password reset"
      assert html =~ "survivor"
      assert html =~ "Revoke all API keys"
      assert {:ok, _} = Accounts.authenticate_user(user.email, "new valid password")
      assert {:ok, _} = Accounts.fetch_api_key_user(key_plaintext)

      # Revoking every key runs through the confirmation modal.
      html = lv |> element("#revoke-all-keys") |> render_click()
      assert html =~ "confirm_modal"
      assert {:ok, _} = Accounts.fetch_api_key_user(key_plaintext)

      lv |> element("#confirm_action") |> render_click()
      assert {:error, :invalid} = Accounts.fetch_api_key_user(key_plaintext)
      assert render(lv) =~ "no active API keys"

      # The token cannot be reused.
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/#{token}")
      assert to.to == ~p"/"
    end

    test "does not reset password on invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "short",
            "password_confirmation" => "does not match"
          }
        )
        |> render_submit()

      assert result =~ "Reset password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end
end
