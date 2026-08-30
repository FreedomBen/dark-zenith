defmodule DarkZenithWeb.NotFoundError do
  @moduledoc """
  Raised to render the standard 404 response from web code, for example when
  registration routes are requested while `REGISTRATION_ENABLED` is false.
  """
  defexception message: "not found", plug_status: 404
end
