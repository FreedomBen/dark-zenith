defmodule DarkZenithWeb.Api.V1.AuthController do
  @moduledoc """
  `POST /api/v1/auth/login` and `DELETE /api/v1/auth/logout`
  (DESIGN.md: REST API — Authentication).
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenithWeb.Api.Strict

  def login(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, body} <-
           Strict.validate_json_body(conn, ["email", "password"], ["email", "password"]),
         {:ok, email, password} <- string_credentials(body) do
      case Accounts.authenticate_user(email, password) do
        {:ok, user} ->
          {plaintext, token} = Accounts.create_session_token(user)

          Audit.record!("auth.login",
            actor: user,
            target: {:user, user.id},
            metadata: %{"surface" => "api"}
          )

          json(conn, %{
            "data" => %{
              "token" => plaintext,
              "expires_at" => DateTime.to_iso8601(token.expires_at)
            }
          })

        {:error, :invalid_credentials} ->
          Audit.record!("auth.login_failed",
            metadata: %{"surface" => "api", "email" => String.slice(email, 0, 160)}
          )

          {:error, :unauthenticated}
      end
    end
  end

  def logout(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn) do
      case conn.assigns.api_principal do
        {:authenticated, _user, {:session_token, plaintext}} ->
          # Idempotent for the presented token: it authenticated above, so it
          # exists; a concurrent delete still yields 204 semantics.
          _ = Accounts.delete_session_token(plaintext)
          send_resp(conn, 204, "")

        {:authenticated, _user, _other_kind} ->
          # Only session tokens can be invalidated through this endpoint.
          {:error, :forbidden}

        _ ->
          {:error, :unauthenticated}
      end
    end
  end

  defp string_credentials(%{"email" => email, "password" => password})
       when is_binary(email) and is_binary(password) do
    {:ok, email |> String.trim() |> String.downcase(), password}
  end

  defp string_credentials(_), do: {:error, :validation_failed}
end
