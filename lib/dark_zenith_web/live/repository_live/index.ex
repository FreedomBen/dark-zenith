defmodule DarkZenithWeb.RepositoryLive.Index do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div>
        <div class="flex items-center justify-between mb-6">
          <.header>
            Repositories
            <:subtitle>Public repositories, plus private ones you can access</:subtitle>
          </.header>
          <.link
            :if={@current_scope && @current_scope.user}
            navigate={~p"/repos/new"}
            class="btn btn-primary"
          >
            Create New Repo
          </.link>
        </div>

        <Layouts.empty_state :if={@repositories == []}>
          No repositories yet.
        </Layouts.empty_state>

        <ul class="space-y-3">
          <li :for={repository <- @repositories} class="card bg-base-200">
            <div class="card-body py-4 flex-row items-center justify-between">
              <div>
                <.link navigate={~p"/repos/#{repository.slug}"} class="font-semibold link">
                  {repository.name}
                </.link>
                <.badge :if={!repository.is_public} variant={:private} class="badge-sm ml-2" />
                <p :if={repository.description} class="text-sm text-base-content/70 mt-1">
                  {repository.description}
                </p>
              </div>
              <div class="text-sm text-base-content/60">
                {repository.package_count} packages
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user
    {:ok, assign(socket, :repositories, Repositories.list_visible_repositories(user))}
  end
end
