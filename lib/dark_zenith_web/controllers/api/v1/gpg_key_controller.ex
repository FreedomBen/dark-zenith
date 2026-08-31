defmodule DarkZenithWeb.Api.V1.GpgKeyController do
  @moduledoc """
  `/api/v1/gpg_key` (DESIGN.md: REST API — GPG Keys). Session token or
  session cookie authentication only; API keys receive `403 forbidden`.
  The upload is a multipart form with exactly `public_key` and
  `private_key` fields, bounded by the endpoint's multipart parser cap.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Accounts
  alias DarkZenithWeb.Api.Strict

  @upload_fields ~w(public_key private_key)

  def show(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn) do
      case Accounts.get_gpg_key_info(user) do
        nil -> {:error, :not_found}
        info -> json(conn, %{"data" => data(info)})
      end
    end
  end

  def update(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn),
         {:ok, public_armored, private_armored} <- validate_multipart(conn) do
      case Accounts.upsert_gpg_key(user, public_armored, private_armored) do
        {:ok, _user} ->
          json(conn, %{"data" => data(Accounts.get_gpg_key_info(user))})

        {:error, :validation_failed} ->
          {:error, :validation_failed}

        {:error, :replacement_not_implemented} ->
          {:error, :service_unavailable, "signing_unavailable", 30}

        {:error, :signing_unavailable} ->
          {:error, :service_unavailable, "signing_unavailable", 30}

        {:error, :rpm_verification_unavailable} ->
          {:error, :service_unavailable, "rpm_verification_unavailable", 30}
      end
    end
  end

  def delete(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn) do
      case Accounts.remove_gpg_key(user) do
        :ok -> send_resp(conn, 204, "")
        {:error, :not_found} -> {:error, :not_found}
        {:error, :in_use} -> {:error, :conflict, "conflict_gpg_key_in_use"}
      end
    end
  end

  ## Helpers

  defp data(info) do
    %{
      "fingerprint" => info.fingerprint,
      "signing_fingerprint" => info.signing_fingerprint,
      "expires_at" => info.expires_at && DateTime.to_iso8601(info.expires_at),
      "public_key" => info.public_key,
      "replacement_in_progress" => info.replacement_in_progress,
      "previous_public_key" => info.previous_public_key,
      "transition" => nil,
      "updated_at" => DateTime.to_iso8601(info.updated_at)
    }
  end

  defp validate_multipart(conn) do
    content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])

    cond do
      is_nil(content_type) or not String.starts_with?(content_type, "multipart/form-data") ->
        {:error, :invalid_request}

      unknown = conn.body_params |> Map.keys() |> Enum.find(&(&1 not in @upload_fields)) ->
        {:error, :validation_failed, %{unknown => ["is not a supported field"]}}

      true ->
        with {:ok, public_armored} <- field_value(conn.body_params, "public_key"),
             {:ok, private_armored} <- field_value(conn.body_params, "private_key") do
          {:ok, public_armored, private_armored}
        end
    end
  end

  defp field_value(params, field) do
    case Map.get(params, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      %Plug.Upload{path: path} ->
        {:ok, File.read!(path)}

      _other ->
        {:error, :validation_failed, %{field => ["can't be blank"]}}
    end
  end

  defp require_session_principal(conn) do
    case conn.assigns.api_principal do
      {:authenticated, _user, {:api_key, _}} -> {:error, :forbidden}
      {:authenticated, user, _kind} -> {:ok, user}
      _ -> {:error, :unauthenticated}
    end
  end
end
