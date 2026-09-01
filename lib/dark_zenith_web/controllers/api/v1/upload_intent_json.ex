defmodule DarkZenithWeb.Api.V1.UploadIntentJSON do
  @moduledoc """
  Upload-intent resource shape (DESIGN.md: API Contract Details). The
  reservation, staging key/version, lease token, and upload generation are
  internal; the generation appears only inside the ephemeral `upload`
  capability object of create/refresh responses.
  """

  alias DarkZenith.Packages
  alias DarkZenith.Uploads.FailureReason
  alias DarkZenithWeb.Api.Errors
  alias DarkZenithWeb.Api.V1.PackageJSON

  def data(intent, repository) do
    %{
      "id" => intent.id,
      "repository_id" => intent.repository_id,
      "package_id" => intent.package_id,
      "mode" => intent.mode,
      "status" => intent.status,
      "original_filename" => intent.original_filename,
      "declared_size" => Integer.to_string(intent.declared_size),
      "attempts" => intent.attempts,
      "expires_at" => maybe_iso8601(intent.expires_at),
      "error" => error(intent),
      "package" => package(intent, repository),
      "completed_at" => maybe_iso8601(intent.completed_at),
      "inserted_at" => DateTime.to_iso8601(intent.inserted_at),
      "updated_at" => DateTime.to_iso8601(intent.updated_at)
    }
  end

  def upload(upload) do
    %{
      "generation" => upload.generation,
      "method" => upload.method,
      "url" => upload.url,
      "headers" => upload.headers,
      "content_length" => Integer.to_string(upload.content_length),
      "expires_at" => DateTime.to_iso8601(upload.expires_at)
    }
  end

  defp error(%{status: "failed", last_error_code: code} = intent) when is_binary(code) do
    %{"code" => code, "message" => Errors.message(code)}
    |> maybe_put_details(intent.last_error_detail)
  end

  defp error(_intent), do: nil

  # A sanitized reason refines the coarse code (DESIGN.md: Upload Failure
  # Reasons). An unrecognized stored value is dropped rather than echoed.
  defp maybe_put_details(error, detail) when is_binary(detail) do
    case FailureReason.message(detail) do
      nil -> error
      message -> Map.put(error, "details", %{"reason" => detail, "message" => message})
    end
  end

  defp maybe_put_details(error, _detail), do: error

  defp package(%{status: "succeeded"} = intent, repository) do
    case Packages.get_package(repository, intent.package_id) do
      nil -> nil
      package -> PackageJSON.detail(package, repository)
    end
  end

  defp package(_intent, _repository), do: nil

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
