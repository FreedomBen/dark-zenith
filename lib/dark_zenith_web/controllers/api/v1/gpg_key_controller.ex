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

        {:accepted, transition} ->
          accepted_transition(conn, transition)

        {:error, :validation_failed} ->
          {:error, :validation_failed}

        {:error, :transition_in_progress} ->
          {:error, :conflict, "conflict_gpg_key_transition_in_progress"}

        {:error, :signing_unavailable} ->
          {:error, :service_unavailable, "signing_unavailable", 30}

        {:error, :rpm_verification_unavailable} ->
          {:error, :service_unavailable, "rpm_verification_unavailable", 30}
      end
    end
  end

  @doc """
  `POST /api/v1/gpg_key/revocation`: removes or replaces an in-use key with
  an explicit strategy. Multipart bodies are accepted only with
  `strategy=replace_key`, so key material can never accompany a
  non-replacement strategy.
  """
  def revocation(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn) do
      if multipart?(conn) do
        multipart_revocation(conn, user)
      else
        json_revocation(conn, user)
      end
    end
  end

  defp multipart_revocation(conn, user) do
    with :ok <- validate_revocation_fields(conn.body_params) do
      case Map.get(conn.body_params, "strategy") do
        "replace_key" ->
          with {:ok, public_armored} <- field_value(conn.body_params, "public_key"),
               {:ok, private_armored} <- field_value(conn.body_params, "private_key") do
            start_replacement(conn, user, public_armored, private_armored)
          end

        _other ->
          # Multipart revocation bodies are accepted only with
          # strategy=replace_key.
          {:error, :validation_failed, %{"strategy" => ["is not a supported strategy"]}}
      end
    end
  end

  defp validate_revocation_fields(params) do
    case params |> Map.keys() |> Enum.find(&(&1 not in ["strategy" | @upload_fields])) do
      nil -> :ok
      unknown -> {:error, :validation_failed, %{unknown => ["is not a supported field"]}}
    end
  end

  defp json_revocation(conn, user) do
    with {:ok, body} <- Strict.validate_json_body(conn, ["strategy"], ["strategy"]) do
      case Map.get(body, "strategy") do
        strategy when strategy in ["clear_metadata_signing", "delete_signed_packages"] ->
          case DarkZenith.SigningTransitions.UserWide.start_removal(user, strategy) do
            {:accepted, transition} -> accepted_transition(conn, transition)
            {:error, :not_found} -> {:error, :not_found}
            {:error, :in_use} -> {:error, :conflict, "conflict_gpg_key_in_use"}

            {:error, :transition_in_progress} ->
              {:error, :conflict, "conflict_gpg_key_transition_in_progress"}
          end

        _other ->
          {:error, :validation_failed, %{"strategy" => ["is not a supported strategy"]}}
      end
    end
  end

  defp start_replacement(conn, user, public_armored, private_armored) do
    case DarkZenith.SigningTransitions.UserWide.start_replacement(
           user,
           public_armored,
           private_armored
         ) do
      {:accepted, transition} ->
        accepted_transition(conn, transition)

      {:error, :no_current_key} ->
        {:error, :not_found}

      {:error, :validation_failed} ->
        {:error, :validation_failed}

      {:error, :transition_in_progress} ->
        {:error, :conflict, "conflict_gpg_key_transition_in_progress"}

      {:error, :signing_unavailable} ->
        {:error, :service_unavailable, "signing_unavailable", 30}

      {:error, :rpm_verification_unavailable} ->
        {:error, :service_unavailable, "rpm_verification_unavailable", 30}
    end
  end

  @doc "`GET /api/v1/gpg_key/transitions/:id`: one retained key-transition resource."
  def transition(conn, %{"id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn) do
      transition = valid_uuid?(id) && DarkZenith.SigningTransitions.get_transition(id)

      cond do
        !transition or transition.user_id != user.id or
            transition.kind == "enable_rpm_signing" ->
          {:error, :not_found}

        transition.status in ["preparing", "activating", "active", "finalizing"] ->
          conn
          |> put_resp_header("retry-after", "2")
          |> json(%{"data" => DarkZenithWeb.Api.V1.GpgTransitionJson.render(transition)})

        true ->
          json(conn, %{"data" => DarkZenithWeb.Api.V1.GpgTransitionJson.render(transition)})
      end
    end
  end

  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp accepted_transition(conn, transition) do
    conn
    |> put_status(202)
    |> put_resp_header("retry-after", "2")
    |> json(%{"data" => DarkZenithWeb.Api.V1.GpgTransitionJson.render(transition)})
  end

  defp multipart?(conn) do
    content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])
    content_type != nil and String.starts_with?(content_type, "multipart/form-data")
  end

  def delete(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_session_principal(conn) do
      case Accounts.remove_gpg_key(user) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :transition_in_progress} ->
          {:error, :conflict, "conflict_gpg_key_transition_in_progress"}

        {:error, {:in_use, counts}} ->
          {:error, :conflict, "conflict_gpg_key_in_use",
           %{
             "metadata_signed_repositories" => Integer.to_string(counts.metadata_signed),
             "rpm_signed_repositories" => Integer.to_string(counts.rpm_signed)
           }}
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
      "transition" =>
        info.transition && DarkZenithWeb.Api.V1.GpgTransitionJson.render(info.transition),
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
