defmodule DarkZenithWeb.AdminLive.Slugs do
  @moduledoc """
  Slug reservation administration (DESIGN.md: Admin): retired reservations
  can be released for general reuse; live ones are visible for diagnosis.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenithWeb.AdminComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <AdminComponents.admin_page
        active="slugs"
        subtitle="Live reservations shown for diagnosis; retired ones can be released for reuse."
      >
        <Layouts.empty_state :if={@reservations == []}>
          No slug reservations.
        </Layouts.empty_state>

        <.table
          :if={@reservations != []}
          id="admin-slugs"
          rows={@reservations}
          row_id={&"slug-#{&1.slug}"}
        >
          <:col :let={reservation} label="Slug" mono>{reservation.slug}</:col>
          <:col :let={reservation} label="Repository name">{reservation.repository_name}</:col>
          <:col :let={reservation} label="State">
            <span :if={reservation.retired_at} class="badge badge-ghost badge-sm">
              retired
            </span>
            <span
              :if={is_nil(reservation.retired_at)}
              class="badge badge-soft badge-success badge-sm"
            >
              live
            </span>
          </:col>
          <:col :let={reservation} label="Retired">
            <span :if={reservation.retired_at} class="whitespace-nowrap text-base-content/70">
              {Calendar.strftime(reservation.retired_at, "%Y-%m-%d")}
            </span>
          </:col>
          <:action :let={reservation}>
            <button
              :if={reservation.retired_at}
              id={"release-#{reservation.slug}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="release"
              phx-value-slug={reservation.slug}
              data-confirm="Release this retired slug for anyone to claim?"
            >
              Release
            </button>
          </:action>
        </.table>
      </AdminComponents.admin_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, reload(socket)}
  end

  @impl true
  def handle_event("release", %{"slug" => slug}, socket) do
    case Repositories.release_retired_slug(socket.assigns.current_scope.user, slug) do
      :ok ->
        {:noreply, socket |> reload() |> put_flash(:info, "Slug released.")}

      {:error, :live_reservation} ->
        {:noreply, put_flash(socket, :error, "Live reservations cannot be released.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The slug could not be released.")}
    end
  end

  defp reload(socket) do
    assign(socket, :reservations, Repositories.list_slug_reservations())
  end
end
