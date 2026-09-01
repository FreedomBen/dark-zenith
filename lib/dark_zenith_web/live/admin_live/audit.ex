defmodule DarkZenithWeb.AdminLive.Audit do
  @moduledoc "Read-only, filterable audit log browser (DESIGN.md: Admin)."

  use DarkZenithWeb, :live_view

  alias DarkZenith.Audit
  alias DarkZenithWeb.AdminComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <AdminComponents.admin_page
        active="audit"
        subtitle="Read-only event log, newest first (most recent 200)."
      >
        <form id="audit-filters" phx-change="filter" class="flex flex-wrap gap-2">
          <label class="sr-only" for="audit-filter-action">Action prefix</label>
          <input
            type="text"
            id="audit-filter-action"
            name="action"
            value={@action}
            placeholder="Action prefix (e.g. auth.)"
            phx-debounce="300"
            class="input input-sm w-56 font-mono"
          />
          <label class="sr-only" for="audit-filter-actor">Actor email</label>
          <input
            type="text"
            id="audit-filter-actor"
            name="actor_email"
            value={@actor_email}
            placeholder="Actor email"
            phx-debounce="300"
            class="input input-sm w-56 font-mono"
          />
        </form>

        <Layouts.empty_state :if={@events == []}>
          No events match the filters.
        </Layouts.empty_state>

        <.table :if={@events != []} id="admin-audit" rows={@events} row_id={&"event-#{&1.id}"}>
          <:col :let={event} label="Time">
            <span class="font-mono whitespace-nowrap text-base-content/70">
              {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S")}
            </span>
          </:col>
          <:col :let={event} label="Actor" mono>{event.actor_email || "system"}</:col>
          <:col :let={event} label="Action" mono>{event.action}</:col>
          <:col :let={event} label="Target">{event.target_type}</:col>
          <:col :let={event} label="Metadata">
            <span class="block max-w-md truncate font-mono text-xs">
              {Jason.encode!(event.metadata)}
            </span>
          </:col>
        </.table>
      </AdminComponents.admin_page>
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
