defmodule DarkZenithWeb.UserSessionControllerTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log-in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_dark_zenith_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "emits error message with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "rejects an unconfirmed user with the same generic message", %{conn: conn} do
      unconfirmed = unconfirmed_user_fixture()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => unconfirmed.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/update-password" do
    test "updates the user password and resets tokens", %{conn: conn, user: user} do
      old_token = DarkZenith.Accounts.generate_user_session_token(user)

      new_password_conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "current_password" => valid_user_password(),
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(new_password_conn) == ~p"/users/settings"
      assert get_session(new_password_conn, :user_token) != old_token
      refute DarkZenith.Accounts.get_user_by_session_token(old_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert {:ok, _} = DarkZenith.Accounts.authenticate_user(user.email, "new valid password")
    end

    test "rejects an invalid current password", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "current_password" => "wrong password!",
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Password update failed"
      assert {:ok, _} = DarkZenith.Accounts.authenticate_user(user.email, valid_user_password())
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/users/update-password", %{"user" => %{}})
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
