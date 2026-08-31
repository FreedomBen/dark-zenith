defmodule DarkZenithWeb.AuditContext do
  @moduledoc """
  Establishes the process-scoped audit context (DESIGN.md: Audit Events):
  the client IP resolved by the client IP detection rules, so every audited
  action recorded during the request — directly or inside context
  functions — carries it without threading it through each call.

  Mounted as a plug in the `:browser` and `:api` pipelines and as an
  `on_mount` hook in every live session, since LiveView events run in the
  socket's own process. Background workers never set the context, so
  system events keep a null `ip`.
  """

  alias DarkZenith.Audit
  alias DarkZenith.ClientIp

  def init(opts), do: opts

  def call(conn, _opts) do
    Audit.put_client_ip(ClientIp.to_string(ClientIp.resolve(conn)))
    conn
  end

  def on_mount(:default, _params, _session, socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: peer} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        Audit.put_client_ip(ClientIp.to_string(ClientIp.resolve_peer(peer, headers)))

      _no_peer ->
        :ok
    end

    {:cont, socket}
  end
end
