defmodule DarkZenithWeb.AdminLive.Audit do
  @moduledoc "Read-only, filterable audit log browser (DESIGN.md: Admin)."

  use DarkZenithWeb, :live_view

  alias DarkZenith.Audit

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-6">
        <.header>
          Audit log
          <:subtitle><DarkZenithWeb.AdminComponents.admin_nav active="audit" /></:subtitle>
        </.header>

        <form id="audit-filters" phx-change="filter" class="flex gap-2">
          <input
            type="text"
            name="action"
            value={@action}
            placeholder="Action prefix (e.g. auth.)"
            phx-debounce="300"
            class="input input-bordered input-sm"
          />
          <input
            type="text"
            name="actor_email"
            value={@actor_email}
            placeholder="Actor email"
            phx-debounce="300"
            class="input input-bordered input-sm"
          />
        </form>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Actor</th>
                <th>Action</th>
                <th>Target</th>
                <th>Metadata</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @events} id={"event-#{event.id}"}>
                <td class="whitespace-nowrap">
                  {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </td>
                <td class="font-mono">{event.actor_email || "system"}</td>
                <td>{event.action}</td>
                <td>{event.target_type}</td>
                <td class="max-w-md truncate font-mono text-xs">
                  {Jason.encode!(event.metadata)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:action, "") |> assign(:actor_email, "") |> reload()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:action, String.slice(params["action"] || "", 0, 100))
     |> assign(:actor_email, String.slice(params["actor_email"] || "", 0, 160))
     |> reload()}
  end

  defp reload(socket) do
    assign(
      socket,
      :events,
      Audit.list_events(
        action: socket.assigns.action,
        actor_email: socket.assigns.actor_email,
        limit: 200
      )
    )
  end
end
