defmodule DarkZenithWeb.AdminLive.Slugs do
  @moduledoc """
  Slug reservation administration (DESIGN.md: Admin): retired reservations
  can be released for general reuse; live ones are visible for diagnosis.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-6">
        <.header>
          Slug reservations
          <:subtitle><DarkZenithWeb.AdminComponents.admin_nav active="slugs" /></:subtitle>
        </.header>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Slug</th>
                <th>Repository name</th>
                <th>State</th>
                <th>Retired</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={reservation <- @reservations} id={"slug-#{reservation.slug}"}>
                <td class="font-mono">{reservation.slug}</td>
                <td>{reservation.repository_name}</td>
                <td>
                  <span :if={reservation.retired_at} class="badge badge-ghost badge-sm">
                    retired
                  </span>
                  <span :if={is_nil(reservation.retired_at)} class="badge badge-success badge-sm">
                    live
                  </span>
                </td>
                <td>
                  <span :if={reservation.retired_at}>
                    {Calendar.strftime(reservation.retired_at, "%Y-%m-%d")}
                  </span>
                </td>
                <td class="text-right">
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
