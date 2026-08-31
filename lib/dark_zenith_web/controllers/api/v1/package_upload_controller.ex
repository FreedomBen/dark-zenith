defmodule DarkZenithWeb.Api.V1.PackageUploadController do
  @moduledoc """
  `/api/v1/repos/:slug/package-uploads` (DESIGN.md: REST API — Packages;
  Upload Intents). API mode is fixed; the ephemeral `upload` capability
  object appears only in create and refresh responses.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Uploads
  alias DarkZenithWeb.Api.{RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.UploadIntentJSON

  def create(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "package:upload"),
         {:ok, body} <- Strict.validate_json_body(conn, ["filename", "size"], ["filename", "size"]),
         {:ok, size} <- parse_size(body["size"]) do
      case Uploads.create_intent(user, repository, %{
             filename: body["filename"],
             size: size,
             mode: "api"
           }) do
        {:ok, intent, upload} ->
          conn
          |> put_status(201)
          |> json(%{
            "data" => UploadIntentJSON.data(intent, repository),
            "upload" => UploadIntentJSON.upload(upload)
          })

        {:error, :invalid_filename} ->
          {:error, :validation_failed, %{"filename" => ["is invalid"]}}

        {:error, :invalid_size} ->
          {:error, :validation_failed, %{"size" => ["must be a positive decimal string"]}}

        {:error, :payload_too_large} ->
          {:error, :payload_too_large}

        {:error, :quota_exceeded} ->
          {:error, :conflict, "conflict_storage_quota_exceeded"}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  def show(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, _user, repository, intent} <- fetch_intent(conn, slug, id) do
      conn
      |> maybe_retry_after(intent)
      |> json(%{"data" => UploadIntentJSON.data(intent, repository)})
    end
  end

  def refresh(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository, intent} <- fetch_intent(conn, slug, id),
         :ok <- Strict.validate_empty_body(conn) do
      case Uploads.refresh_intent(user, intent) do
        {:ok, refreshed, upload} ->
          json(conn, %{
            "data" => UploadIntentJSON.data(refreshed, repository),
            "upload" => UploadIntentJSON.upload(upload)
          })

        {:error, :upload_state} ->
          {:error, :conflict, "conflict_upload_state"}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  def complete(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository, intent} <- fetch_intent(conn, slug, id),
         {:ok, body} <-
           Strict.validate_json_body(conn, ["generation", "version_id"], [
             "generation",
             "version_id"
           ]),
         {:ok, generation} <- parse_generation(body["generation"]) do
      case Uploads.complete_intent(user, intent, generation, body["version_id"]) do
        {:ok, completed} ->
          conn
          |> put_status(202)
          |> put_resp_header("retry-after", "2")
          |> json(%{"data" => UploadIntentJSON.data(completed, repository)})

        {:error, :upload_state} ->
          {:error, :conflict, "conflict_upload_state"}

        {:error, :validation_failed} ->
          {:error, :validation_failed}

        {:error, :storage_unavailable} ->
          {:error, :service_unavailable, "storage_unavailable", 30}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  def delete(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, _repository, intent} <- fetch_intent(conn, slug, id) do
      case Uploads.cancel_intent(user, intent) do
        {:ok, _} -> send_resp(conn, 204, "")
        {:error, :upload_state} -> {:error, :conflict, "conflict_upload_state"}
        {:error, other} -> {:error, other}
      end
    end
  end

  ## Helpers

  defp fetch_intent(conn, slug, id) do
    with {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "package:upload") do
      case Uploads.get_intent(repository, id) do
        nil -> {:error, :not_found}
        intent -> {:ok, user, repository, intent}
      end
    end
  end

  # Declared sizes travel as decimal strings, like every bigint in this API.
  defp parse_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} -> {:ok, size}
      _ -> {:error, :validation_failed, %{"size" => ["must be a decimal string"]}}
    end
  end

  defp parse_size(_value),
    do: {:error, :validation_failed, %{"size" => ["must be a decimal string"]}}

  defp parse_generation(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp parse_generation(_value),
    do: {:error, :validation_failed, %{"generation" => ["must be a positive integer"]}}

  defp maybe_retry_after(conn, intent) do
    if intent.status in ["queued", "processing"] do
      put_resp_header(conn, "retry-after", "2")
    else
      conn
    end
  end
end
