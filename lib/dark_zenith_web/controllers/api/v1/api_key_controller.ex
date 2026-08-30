defmodule DarkZenithWeb.Api.V1.ApiKeyController do
  @moduledoc """
  `/api/v1/api_keys` (DESIGN.md: REST API — API Keys). These routes require
  session token or session cookie authentication; API keys cannot manage API
  keys and receive `403 forbidden`.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenithWeb.Api.{Pagination, Strict}
  alias DarkZenithWeb.Api.V1.ApiKeyJSON

  def index(conn, _params) do
    with {:ok, params} <- Strict.validate_query(conn, ["page", "per_page"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, user} <- require_session_principal(conn) do
      {keys, total} =
        user
        |> Accounts.api_keys_query()
        |> Pagination.paginate(page, per_page)

      json(conn, Pagination.envelope(Enum.map(keys, &ApiKeyJSON.data/1), page, per_page, total))
    end
  end

  def create(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn),
         {:ok, body} <-
           Strict.validate_json_body(conn, ["name", "scopes", "expires_at"], ["name", "scopes"]),
         {:ok, expires_at} <- parse_expires_at(body) do
      attrs = %{name: body["name"], scopes: body["scopes"], expires_at: expires_at}

      case Accounts.create_api_key(user, attrs) do
        {:ok, {plaintext, api_key}} ->
          Audit.record!("api_key.create",
            actor: user,
            target: {:api_key, api_key.id},
            ip: client_ip(conn),
            metadata: %{"name" => api_key.name, "scopes" => api_key.scopes}
          )

          conn
          |> put_status(201)
          |> json(%{"data" => ApiKeyJSON.data(api_key, plaintext)})

        {:error, :quota_exceeded} ->
          {:error, :conflict, "conflict_api_key_quota_exceeded"}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn),
         {:ok, uuid} <- cast_uuid(id) do
      case Accounts.delete_api_key(user, uuid) do
        :ok ->
          Audit.record!("api_key.revoke",
            actor: user,
            target: {:api_key, uuid},
            ip: client_ip(conn)
          )

          send_resp(conn, 204, "")

        :error ->
          {:error, :not_found}
      end
    end
  end

  # Session token or session cookie only; API keys receive 403.
  defp require_session_principal(conn) do
    case conn.assigns.api_principal do
      {:authenticated, _user, {:api_key, _}} -> {:error, :forbidden}
      {:authenticated, user, _kind} -> {:ok, user}
      _ -> {:error, :unauthenticated}
    end
  end

  defp parse_expires_at(%{"expires_at" => nil}), do: {:ok, nil}

  defp parse_expires_at(%{"expires_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :validation_failed, %{"expires_at" => ["must be an ISO-8601 UTC timestamp"]}}
    end
  end

  defp parse_expires_at(%{"expires_at" => _}) do
    {:error, :validation_failed, %{"expires_at" => ["must be an ISO-8601 UTC timestamp"]}}
  end

  defp parse_expires_at(_body), do: {:ok, nil}

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
