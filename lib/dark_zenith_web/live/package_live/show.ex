defmodule DarkZenithWeb.PackageLive.Show do
  @moduledoc """
  Package Detail (`GET /repos/:slug/packages/:name`) — all builds of one
  package name with install instructions (DESIGN.md: Web Interface).
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Packages
  alias DarkZenith.Repositories

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <.header>
          {@name}
          <:subtitle>
            <.link navigate={~p"/repos/#{@repository.slug}"} class="link">
              {@repository.name}
            </.link>
          </:subtitle>
        </.header>

        <section :if={@install_command || @source_command}>
          <h2 class="text-lg font-semibold mb-2">Install</h2>
          <p class="text-sm text-base-content/70 mb-2">
            Assumes the repository is already configured on your system.
          </p>
          <pre :if={@install_command} class="bg-base-200 rounded-lg p-4 text-sm overflow-x-auto"><code>{@install_command}</code></pre>
          <pre :if={@source_command} class="bg-base-200 rounded-lg p-4 text-sm overflow-x-auto mt-2"><code>{@source_command}</code></pre>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-2">Builds</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>EVR</th>
                  <th>Arch</th>
                  <th>Summary</th>
                  <th>Size</th>
                  <th>Uploaded</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={package <- @packages} id={"build-#{package.id}"}>
                  <td>
                    <.link
                      navigate={~p"/repos/#{@repository.slug}/package-versions/#{package.id}"}
                      class="link font-mono"
                    >
                      {Packages.display_evr(package)}
                    </.link>
                  </td>
                  <td>{package.arch}</td>
                  <td class="max-w-xs truncate">{package.summary}</td>
                  <td>{format_bytes(package.size_package)}</td>
                  <td>{Calendar.strftime(package.inserted_at, "%Y-%m-%d")}</td>
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
  def mount(%{"slug" => slug, "name" => name}, _session, socket) do
    repository = Repositories.get_repository_by_slug(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    cond do
      repository && DarkZenith.Authorization.can_read?(user, repository) ->
        case Packages.builds_for_name(repository, name) do
          [] ->
            raise DarkZenithWeb.NotFoundError

          packages ->
            arches = packages |> Enum.map(& &1.arch) |> Enum.uniq()
            source_only? = arches == ["src"]
            has_source? = "src" in arches

            {:ok,
             socket
             |> assign(:repository, repository)
             |> assign(:name, name)
             |> assign(:packages, packages)
             |> assign(:install_command, if(source_only?, do: nil, else: "dnf install #{name}"))
             |> assign(
               :source_command,
               if(has_source?, do: "dnf download --source #{name}", else: nil)
             )}
        end

      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "You must log in to access this page.")
         |> redirect(to: ~p"/users/log-in")}

      true ->
        raise DarkZenithWeb.NotFoundError
    end
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
