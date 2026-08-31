defmodule DarkZenithWeb.AdminLive.Transitions do
  @moduledoc """
  Signing-transition administration (DESIGN.md: Admin): a durable
  transition/repository/item view independent of Oban retention, with
  phase reset, failed-item reset, and cancellation where the flow permits.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.SigningTransitions

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl space-y-6">
        <.header>
          Signing transitions
          <:subtitle><DarkZenithWeb.AdminComponents.admin_nav active="transitions" /></:subtitle>
        </.header>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Kind</th>
                <th>Status</th>
                <th>Phase attempts</th>
                <th>Next run</th>
                <th>Target</th>
                <th>Last error</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={transition <- @transitions} id={"transition-#{transition.id}"}>
                <td>{transition.kind}</td>
                <td>
                  {transition.status}<span :if={transition.resume_status}>
                    → {transition.resume_status}</span>
                </td>
                <td>{transition.phase_attempts}</td>
                <td>
                  <span :if={transition.phase_next_attempt_at}>
                    {Calendar.strftime(transition.phase_next_attempt_at, "%H:%M:%S")}
                  </span>
                </td>
                <td class="font-mono text-xs">{transition.target_fingerprint}</td>
                <td class="font-mono text-xs">{transition.last_error_code}</td>
                <td>{Calendar.strftime(transition.inserted_at, "%Y-%m-%d %H:%M")}</td>
                <td class="text-right whitespace-nowrap">
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
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <section :if={@inspected} class="space-y-3" id="transition-detail">
          <h2 class="text-lg font-semibold">
            Transition {@inspected.id}
          </h2>
          <p class="text-sm">
            Repositories: {@repository_counts["applied"]} applied,
            {@repository_counts["satisfied_deleted"]} satisfied by deletion,
            {@repository_counts["pending"]} pending ·
            Items: {@item_counts["succeeded"]} succeeded, {@item_counts["failed"]} failed,
            {@item_counts["pending"]} pending, {@item_counts["executing"]} executing,
            {@item_counts["canceled"]} canceled
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

          <div class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Package</th>
                  <th>Repository</th>
                  <th>Status</th>
                  <th>Attempts</th>
                  <th>Lease expires</th>
                  <th>Last error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @items} id={"item-#{item.id}"}>
                  <td class="font-mono text-xs">{item.package_id}</td>
                  <td class="font-mono text-xs">{item.repository_id}</td>
                  <td>{item.status}</td>
                  <td>{item.attempts}</td>
                  <td>
                    <span :if={item.lease_expires_at}>
                      {Calendar.strftime(item.lease_expires_at, "%H:%M:%S")}
                    </span>
                  </td>
                  <td class="font-mono text-xs">{item.last_error_code}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
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
