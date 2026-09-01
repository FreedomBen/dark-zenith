defmodule DarkZenithWeb.AdminLive.Transitions do
  @moduledoc """
  Signing-transition administration (DESIGN.md: Admin): a durable
  transition/repository/item view independent of Oban retention, with
  phase reset, failed-item reset, and cancellation where the flow permits.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.SigningTransitions
  alias DarkZenithWeb.AdminComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <AdminComponents.admin_page
        active="transitions"
        subtitle="Durable signing-transition state, independent of Oban retention, with phase reset and cancellation."
      >
        <Layouts.empty_state :if={@transitions == []}>
          No signing transitions yet.
        </Layouts.empty_state>

        <.table
          :if={@transitions != []}
          id="admin-transitions"
          rows={@transitions}
          row_id={&"transition-#{&1.id}"}
        >
          <:col :let={transition} label="Kind" mono>{transition.kind}</:col>
          <:col :let={transition} label="Status">
            <span class={["badge badge-sm", status_badge(transition.status)]}>
              {transition.status}
            </span>
            <span :if={transition.resume_status} class="whitespace-nowrap text-base-content/70">
              → {transition.resume_status}
            </span>
          </:col>
          <:col :let={transition} label="Phase attempts" align={:right}>
            <span class="font-mono">{transition.phase_attempts}</span>
          </:col>
          <:col :let={transition} label="Next run">
            <span :if={transition.phase_next_attempt_at} class="font-mono whitespace-nowrap">
              {Calendar.strftime(transition.phase_next_attempt_at, "%H:%M:%S")}
            </span>
          </:col>
          <:col :let={transition} label="Target">
            <span class="block max-w-40 truncate font-mono text-xs">
              {transition.target_fingerprint}
            </span>
          </:col>
          <:col :let={transition} label="Last error">
            <span class="font-mono text-xs">{transition.last_error_code}</span>
          </:col>
          <:col :let={transition} label="Created">
            <span class="whitespace-nowrap text-base-content/70">
              {Calendar.strftime(transition.inserted_at, "%Y-%m-%d %H:%M")}
            </span>
          </:col>
          <:action :let={transition}>
            <span class="flex justify-end gap-1 whitespace-nowrap">
              <button
                id={"inspect-#{transition.id}"}
                class="btn btn-ghost btn-xs"
                phx-click="inspect"
                phx-value-id={transition.id}
              >
                Inspect
              </button>
              <button
                :if={transition.status == "failed"}
                id={"reset-phase-#{transition.id}"}
                class="btn btn-ghost btn-xs"
                phx-click="reset_phase"
                phx-value-id={transition.id}
                data-confirm="Restore this transition to its recorded phase with a fresh attempt budget?"
              >
                Reset phase
              </button>
              <button
                :if={transition.status not in ["completed", "canceled"]}
                id={"cancel-#{transition.id}"}
                class="btn btn-ghost btn-xs text-error"
                phx-click="cancel"
                phx-value-id={transition.id}
                data-confirm="Cancel this transition?"
              >
                Cancel
              </button>
            </span>
          </:action>
        </.table>

        <section
          :if={@inspected}
          class="space-y-3 rounded-box border border-base-content/10 p-6"
          id="transition-detail"
        >
          <h2 class="text-lg font-semibold">
            Transition <span class="font-mono">{@inspected.id}</span>
          </h2>
          <p class="text-sm">
            Repositories: {@repository_counts["applied"]} applied, {@repository_counts[
              "satisfied_deleted"
            ]} satisfied by deletion, {@repository_counts["pending"]} pending ·
            Items: {@item_counts["succeeded"]} succeeded, {@item_counts["failed"]} failed, {@item_counts[
              "pending"
            ]} pending, {@item_counts["executing"]} executing, {@item_counts["canceled"]} canceled
          </p>

          <button
            :if={@item_counts["failed"] > 0}
            id="reset-failed-items"
            class="btn btn-warning btn-sm"
            phx-click="reset_failed_items"
            data-confirm="Reset every failed item to pending with a fresh attempt budget?"
          >
            Reset failed items
          </button>

          <.table id="transition-items" rows={@items} row_id={&"item-#{&1.id}"}>
            <:col :let={item} label="Package">
              <span class="font-mono text-xs">{item.package_id}</span>
            </:col>
            <:col :let={item} label="Repository">
              <span class="font-mono text-xs">{item.repository_id}</span>
            </:col>
            <:col :let={item} label="Status">
              <span class={["badge badge-sm", status_badge(item.status)]}>
                {item.status}
              </span>
            </:col>
            <:col :let={item} label="Attempts" align={:right}>
              <span class="font-mono">{item.attempts}</span>
            </:col>
            <:col :let={item} label="Lease expires">
              <span :if={item.lease_expires_at} class="font-mono whitespace-nowrap">
                {Calendar.strftime(item.lease_expires_at, "%H:%M:%S")}
              </span>
            </:col>
            <:col :let={item} label="Last error">
              <span class="font-mono text-xs">{item.last_error_code}</span>
            </:col>
          </.table>
        </section>
      </AdminComponents.admin_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:inspected, nil) |> reload()}
  end

  @impl true
  def handle_event("inspect", %{"id" => id}, socket) do
    {:noreply, inspect_transition(socket, id)}
  end

  def handle_event("reset_phase", %{"id" => id}, socket) do
    case SigningTransitions.admin_reset_phase(socket.assigns.current_scope.user, id) do
      :ok ->
        {:noreply, socket |> reload() |> refresh_inspected() |> put_flash(:info, "Phase reset.")}

      {:error, :not_failed} ->
        {:noreply, put_flash(socket, :error, "Only failed transitions can be reset.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The transition could not be reset.")}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case SigningTransitions.admin_cancel_transition(socket.assigns.current_scope.user, id) do
      :ok ->
        {:noreply,
         socket |> reload() |> refresh_inspected() |> put_flash(:info, "Transition canceled.")}

      {:error, :not_cancelable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This transition cannot be canceled in its current phase: " <>
             "a post-swap replacement finishes only by reset/resume or a key-removal flow."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The transition could not be canceled.")}
    end
  end

  def handle_event("reset_failed_items", _params, socket) do
    transition = socket.assigns.inspected

    failed_ids =
      for item <- socket.assigns.items, item.status == "failed", do: item.id

    case SigningTransitions.admin_reset_items(
           socket.assigns.current_scope.user,
           transition.id,
           failed_ids
         ) do
      {:ok, count} ->
        {:noreply,
         socket
         |> reload()
         |> refresh_inspected()
         |> put_flash(:info, "#{count} items reset to pending.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The items could not be reset.")}
    end
  end

  defp reload(socket) do
    assign(socket, :transitions, SigningTransitions.admin_list_transitions())
  end

  # In-flight states are warning-toned, matching the spec's signing badge;
  # canceled is ghost, never soft neutral (docs/DESIGN_UI.md — Badges).
  defp status_badge("failed"), do: "badge-soft badge-error"

  defp status_badge(status) when status in ["completed", "succeeded"],
    do: "badge-soft badge-success"

  defp status_badge("canceled"), do: "badge-ghost"
  defp status_badge(_in_flight), do: "badge-soft badge-warning"

  defp refresh_inspected(socket) do
    case socket.assigns.inspected do
      nil -> socket
      transition -> inspect_transition(socket, transition.id)
    end
  end

  defp inspect_transition(socket, id) do
    case SigningTransitions.get_transition(id) do
      nil ->
        assign(socket, :inspected, nil)

      transition ->
        socket
        |> assign(:inspected, transition)
        |> assign(:items, SigningTransitions.list_items(transition.id))
        |> assign(:item_counts, SigningTransitions.item_counts(transition.id))
        |> assign(:repository_counts, SigningTransitions.repository_counts(transition.id))
    end
  end
end
