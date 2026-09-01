defmodule DarkZenithWeb.RepositoryLive.Index do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div>
        <.header>
          Repositories
          <:subtitle>Public repositories, plus private ones you can access</:subtitle>
          <:actions>
            <.link
              :if={@current_scope && @current_scope.user}
              navigate={~p"/repos/new"}
              class="btn btn-primary"
            >
              Create New Repo
            </.link>
          </:actions>
        </.header>

        <Layouts.empty_state :if={@repositories == []}>
          No repositories yet.
        </Layouts.empty_state>

        <.table
          :if={@repositories != []}
          id="repositories"
          rows={@repositories}
          row_id={&"repo-#{&1.id}"}
        >
          <:col :let={repository} label="Name">
            <.link navigate={~p"/repos/#{repository.slug}"} class="link font-medium">
              {repository.name}
            </.link>
            <span class="ml-2 font-mono text-xs text-base-content/70">{repository.slug}</span>
          </:col>
          <:col :let={repository} label="Description">
            <span class="block max-w-md truncate text-base-content/70">
              {repository.description}
            </span>
          </:col>
          <:col :let={repository} label="Packages" align={:right}>
            {repository.package_count}
          </:col>
          <:col :let={repository} label="Visibility">
            <.badge
              variant={if repository.is_public, do: :public, else: :private}
              class="badge-sm"
            />
          </:col>
        </.table>
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
