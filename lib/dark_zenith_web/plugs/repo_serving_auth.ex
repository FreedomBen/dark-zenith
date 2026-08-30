defmodule DarkZenithWeb.Plugs.RepoServingAuth do
  @moduledoc """
  Credential resolution for repository-serving endpoints (DESIGN.md: Private
  Repository Authentication).

  Assigns `:repo_principal` as one of:

    * `{:authenticated, user, kind}` — kind is `{:api_key, key}`,
      `:session_token`, or `:cookie`
    * `:anonymous` — no credentials at all
    * `:invalid_credential` — a presented `Authorization` value that failed
      validation or used an unsupported scheme; never falls back
    * `:invalid_cookie` — a stale/invalid session cookie with no
      `Authorization` header (anonymous for public reads, masked on private)

  An `Authorization` header is authoritative whenever present. `Basic` and
  `Bearer` are the only recognized schemes: the Basic password is an API key
  (the username is ignored), and a Bearer value may be an API key or a session
  token.
  """

  import Plug.Conn

  alias DarkZenith.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :repo_principal, resolve(conn))
  end

  defp resolve(conn) do
    case get_req_header(conn, "authorization") do
      [] -> resolve_cookie(conn)
      [header] -> resolve_authorization(header)
      _multiple -> :invalid_credential
    end
  end

  defp resolve_authorization("Basic " <> encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [_username, password] <- String.split(decoded, ":", parts: 2) do
      resolve_api_key(password)
    else
      _ -> :invalid_credential
    end
  end

  defp resolve_authorization("Bearer " <> token) do
    case token do
      "dzak_" <> _ ->
        resolve_api_key(token)

      "dzst_" <> _ ->
        case Accounts.get_user_by_api_session_token(token) do
          nil -> :invalid_credential
          user -> {:authenticated, user, :session_token}
        end

      _ ->
        :invalid_credential
    end
  end

  defp resolve_authorization(_other_scheme), do: :invalid_credential

  defp resolve_api_key(value) do
    case Accounts.fetch_api_key_user(value) do
      {:ok, {user, key}} -> {:authenticated, user, {:api_key, key}}
      {:error, :invalid} -> :invalid_credential
    end
  end

  defp resolve_cookie(conn) do
    case get_session(conn, :user_token) do
      nil ->
        :anonymous

      token ->
        case Accounts.get_user_by_session_token(token) do
          {user, _inserted_at} -> {:authenticated, user, :cookie}
          nil -> :invalid_cookie
        end
    end
  end
end
