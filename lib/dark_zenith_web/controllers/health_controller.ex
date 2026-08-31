defmodule DarkZenithWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness probe (DESIGN.md: Deployment). No database or
  B2 calls — process liveness only — and excluded from rate limiting.
  """

  use DarkZenithWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
