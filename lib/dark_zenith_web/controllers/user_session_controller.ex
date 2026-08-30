defmodule DarkZenithWeb.UserSessionController do
  use DarkZenithWeb, :controller

  alias DarkZenith.Accounts
  alias DarkZenithWeb.UserAuth

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params

    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome back!")
        |> UserAuth.log_in_user(user, user_params)

      {:error, :invalid_credentials} ->
        # To prevent user enumeration attacks (and to avoid revealing whether
        # an account is unconfirmed), don't disclose the failure reason.
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    current_password = Map.get(user_params, "current_password", "")

    case Accounts.update_user_password(user, current_password, user_params) do
      {:ok, {user, expired_tokens}} ->
        # disconnect all existing LiveViews with old sessions
        UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:info, "Password updated successfully!")
        |> UserAuth.log_in_user(user, user_params)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Password update failed.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
