defmodule DarkZenithWeb.Api.FallbackController do
  @moduledoc """
  Maps controller error tuples to the `/api/v1` error envelope.
  """

  use DarkZenithWeb, :controller

  alias DarkZenithWeb.Api.Errors

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    Errors.send_error(conn, 422, "validation_failed",
      details: Errors.changeset_details(changeset)
    )
  end

  def call(conn, {:error, :invalid_request}) do
    Errors.send_error(conn, 400, "invalid_request")
  end

  def call(conn, {:error, :unauthenticated}) do
    Errors.send_error(conn, 401, "unauthenticated")
  end

  def call(conn, {:error, :forbidden}) do
    Errors.send_error(conn, 403, "forbidden")
  end

  def call(conn, {:error, :not_found}) do
    Errors.send_error(conn, 404, "not_found")
  end

  def call(conn, {:error, :validation_failed}) do
    Errors.send_error(conn, 422, "validation_failed")
  end

  def call(conn, {:error, :payload_too_large}) do
    Errors.send_error(conn, 413, "payload_too_large")
  end

  def call(conn, {:error, :validation_failed, details}) do
    Errors.send_error(conn, 422, "validation_failed", details: details)
  end

  def call(conn, {:error, :conflict, code}) do
    Errors.send_error(conn, 409, code)
  end

  def call(conn, {:error, :conflict, code, details}) do
    Errors.send_error(conn, 409, code, details: details)
  end

  def call(conn, {:error, :service_unavailable, code, retry_after}) do
    Errors.send_error(conn, 503, code, retry_after: retry_after)
  end
end
