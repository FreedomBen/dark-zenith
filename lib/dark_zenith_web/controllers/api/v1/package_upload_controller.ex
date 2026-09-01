defmodule DarkZenithWeb.Api.V1.PackageUploadController do
  @moduledoc """
  `/api/v1/repos/:slug/package-uploads` (DESIGN.md: REST API — Packages;
  Upload Intents; API Contract Details). API mode is fixed; the ephemeral
  `upload` capability object appears only in create and refresh responses.

  The collection `GET` lists the repository's durable Package Upload
  Records for the owner or an admin (`repo:read` on API keys) regardless
  of initiator; every id-addressed action acts on the live intent and is
  initiator-only, answering another user's intent with the masked 404.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Records
  alias DarkZenithWeb.Api.{Pagination, RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.{UploadIntentJSON, UploadRecordJSON}

  def index(conn, %{"slug" => slug}) do
    with {:ok, params} <- Strict.validate_query(conn, ["page", "per_page", "outcome"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, outcomes} <- parse_outcome(params),
         {:ok, _user, repository} <- RepoAccess.fetch_manageable(conn, slug, "repo:read") do
      {records, total} =
        Uploads.list_repository_records(repository,
          outcomes: outcomes,
          page: page,
          per_page: per_page
        )

      data = Enum.map(records, &UploadRecordJSON.row/1)
      json(conn, Pagination.envelope(data, page, per_page, total))
    end
  end

  def create(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "package:upload"),
         {:ok, body} <-
           Strict.validate_json_body(conn, ["filename", "size"], ["filename", "size"]),
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
          # 202 with Retry-After while queued/processing (including the first
          # acceptance); an idempotent replay of a preview_ready, succeeded,
          # or failed intent is a plain 200 (DESIGN.md: POST .../complete).
          conn = json_status(conn, completed)
          json(conn, %{"data" => UploadIntentJSON.data(completed, repository)})

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

  # Another user's intent is nonexistent here, exactly like an id scoped to
  # a different repository (DESIGN.md: REST API).
  defp fetch_intent(conn, slug, id) do
    with {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "package:upload") do
      case Uploads.get_intent_for(user, repository, id) do
        nil -> {:error, :not_found}
        intent -> {:ok, user, repository, intent}
      end
    end
  end

  defp parse_outcome(params) do
    case Records.parse_outcome_filter(params["outcome"]) do
      {:ok, outcomes} -> {:ok, outcomes}
      {:error, message} -> {:error, :validation_failed, %{"outcome" => [message]}}
    end
  end

  # Declared sizes travel as canonical decimal strings, like every bigint in
  # this API: exactly "0" or [1-9][0-9]* — signs, decimals, exponent
  # notation, whitespace, and leading zeros are rejected (DESIGN.md: API
  # Contract Details).
  defp parse_size(value) when is_binary(value) do
    if value == "0" or value =~ ~r/^[1-9][0-9]*$/ do
      {:ok, String.to_integer(value)}
    else
      {:error, :validation_failed, %{"size" => ["must be a decimal string"]}}
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

  defp json_status(conn, intent) do
    if intent.status in ["queued", "processing"] do
      conn
      |> put_status(202)
      |> put_resp_header("retry-after", "2")
    else
      conn
    end
  end
end
