defmodule DarkZenithWeb.Api.V1.UploadRecordJSON do
  @moduledoc """
  Upload record row shape for `GET /api/v1/repos/:slug/package-uploads`
  (DESIGN.md: API Contract Details). Sizes are decimal strings under the
  bigint rule; `user_id` is never serialized; a row never carries an
  `upload` capability, staging key/version, lease token, or preview
  metadata.
  """

  alias DarkZenith.Uploads.FailureReason

  def row(record) do
    %{
      "id" => record.id,
      "repository_id" => record.repository_id,
      "repository_slug" => record.repository_slug,
      "user_email" => record.user_email,
      "intent_id" => record.intent_id,
      "package_id" => record.package_id,
      "mode" => record.mode,
      "original_filename" => record.original_filename,
      "declared_size" => Integer.to_string(record.declared_size),
      "final_size" => maybe_decimal(record.final_size),
      "outcome" => record.outcome,
      "live_status" => record.live_status,
      "error_code" => record.error_code,
      "error_detail" => sanitized_detail(record.error_detail),
      "nevra" => record.nevra,
      "started_at" => DateTime.to_iso8601(record.started_at),
      "finished_at" => maybe_iso8601(record.finished_at)
    }
  end

  # A stored reason outside the closed vocabulary is never echoed.
  defp sanitized_detail(detail) when is_binary(detail) do
    if FailureReason.message(detail), do: detail, else: nil
  end

  defp sanitized_detail(_detail), do: nil

  defp maybe_decimal(nil), do: nil
  defp maybe_decimal(value) when is_integer(value), do: Integer.to_string(value)

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
