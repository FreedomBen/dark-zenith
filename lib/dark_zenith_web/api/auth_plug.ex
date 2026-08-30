defmodule DarkZenithWeb.Api.AuthPlug do
  @moduledoc """
  Credential resolution for `/api/v1` endpoints (DESIGN.md: REST API).

  Authentication is `Authorization: Bearer <token>` (an API key or a session
  token) or the web session cookie; when both are present, the header takes
  precedence and the cookie is ignored.

  Assigns `:api_principal`:

    * `{:authenticated, user, kind}` — kind is `{:api_key, key}`,
      `{:session_token, plaintext}`, or `:cookie`
    * `:anonymous` — no credentials (a stale cookie with no header is treated
      as anonymous, mirroring the repository-serving surface)
    * `:invalid_credential` — a presented Authorization value that failed
      validation or used an unsupported scheme
  """

  import Plug.Conn

  alias DarkZenith.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :api_principal, resolve(conn))
  end

  defp resolve(conn) do
    case get_req_header(conn, "authorization") do
      [] -> resolve_cookie(conn)
      ["Bearer " <> token] -> resolve_bearer(token)
      [_other] -> :invalid_credential
      _multiple -> :invalid_credential
    end
  end

  defp resolve_bearer("dzak_" <> _ = token) do
    case Accounts.fetch_api_key_user(token) do
      {:ok, {user, key}} -> {:authenticated, user, {:api_key, key}}
      {:error, :invalid} -> :invalid_credential
    end
  end

  defp resolve_bearer("dzst_" <> _ = token) do
    case Accounts.get_user_by_api_session_token(token) do
      nil -> :invalid_credential
      user -> {:authenticated, user, {:session_token, token}}
    end
  end

  defp resolve_bearer(_), do: :invalid_credential

  defp resolve_cookie(conn) do
    case get_session(conn, :user_token) do
      nil ->
        :anonymous

      token ->
        case Accounts.get_user_by_session_token(token) do
          {user, _inserted_at} -> {:authenticated, user, :cookie}
          nil -> :anonymous
        end
    end
  end
end
