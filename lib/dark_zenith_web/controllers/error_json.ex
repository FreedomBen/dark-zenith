defmodule DarkZenithWeb.ErrorJSON do
  @moduledoc """
  Renders raised errors on JSON requests using the `/api/v1` error envelope
  (DESIGN.md: API Contract Details). Controller-level errors go through
  `DarkZenithWeb.Api.FallbackController`; this module covers exceptions
  translated by the endpoint (bad JSON, oversized bodies, missing routes,
  crashes).
  """

  alias DarkZenithWeb.Api.Errors

  # Plug.Parsers raises 415 for unsupported media types; the API contract
  # folds that into 400 invalid_request at the body level while the HTTP
  # status remains what the exception carries.
  @codes %{
    400 => "invalid_request",
    401 => "unauthenticated",
    403 => "forbidden",
    404 => "not_found",
    413 => "payload_too_large",
    415 => "invalid_request",
    422 => "validation_failed",
    429 => "rate_limited",
    500 => "internal_error"
  }

  def render(template, _assigns) do
    status =
      template
      |> String.split(".")
      |> hd()
      |> Integer.parse()
      |> case do
        {status, _} -> status
        :error -> 500
      end

    code = Map.get(@codes, status, "internal_error")

    %{"error" => %{"code" => code, "message" => Errors.message(code)}}
  end
end
