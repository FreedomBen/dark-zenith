defmodule DarkZenithWeb.Api.Errors do
  @moduledoc """
  The `/api/v1` JSON error envelope (DESIGN.md: API Contract Details):

      {"error": {"code": "...", "message": "...", "details": {...}}}

  `details` is included only when field-level or structured information is
  available.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @messages %{
    "invalid_request" => "Invalid request",
    "unauthenticated" => "Authentication required or credentials invalid",
    "forbidden" => "Insufficient permissions for this operation",
    "not_found" => "Not found",
    "conflict_api_key_quota_exceeded" => "API key creation would exceed your key limit",
    "conflict_collaborator_quota_exceeded" =>
      "Collaborator addition would exceed the repository's limit",
    "conflict_duplicate_package" => "A package with the same NEVRA already exists",
    "conflict_gpg_key_expired" => "The configured signing key has expired",
    "conflict_gpg_key_in_use" => "GPG key is still used by repositories",
    "conflict_gpg_key_transition_in_progress" =>
      "A signing or key transition blocks this operation",
    "conflict_repository_metadata_limit_exceeded" =>
      "The mutation would exceed a repository metadata limit",
    "conflict_repository_quota_exceeded" =>
      "Repository creation would exceed your repository limit",
    "conflict_storage_quota_exceeded" => "The operation would exceed your storage quota",
    "conflict_upload_state" => "The upload is not in a state that allows this operation",
    "conflict_user_owns_repositories" => "The user still owns repositories",
    "payload_too_large" => "Request payload exceeds the applicable limit",
    "validation_failed" => "Validation failed",
    "rate_limited" => "Request exceeded the applicable rate limit",
    "internal_error" => "Unexpected server error",
    "rpm_verification_unavailable" => "RPM verification tooling is temporarily unavailable",
    "signing_unavailable" => "RPM signing is temporarily unavailable",
    "storage_unavailable" => "Object storage is temporarily unavailable",
    "upload_temp_space_unavailable" => "Temporary processing workspace is temporarily unavailable"
  }

  @doc "The standard message for an error code."
  def message(code), do: Map.get(@messages, code, "Error")

  @doc "Sends the JSON error envelope with the given HTTP status and code."
  def send_error(conn, status, code, opts \\ []) do
    error =
      %{"code" => code, "message" => Keyword.get(opts, :message, message(code))}
      |> maybe_put_details(Keyword.get(opts, :details))

    conn
    |> put_status(status)
    |> maybe_retry_after(Keyword.get(opts, :retry_after))
    |> json(%{"error" => error})
    |> halt()
  end

  @doc "Formats changeset errors as the `details` map."
  def changeset_details(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp maybe_put_details(error, nil), do: error
  defp maybe_put_details(error, details), do: Map.put(error, "details", details)

  defp maybe_retry_after(conn, nil), do: conn

  defp maybe_retry_after(conn, seconds),
    do: put_resp_header(conn, "retry-after", to_string(seconds))
end
