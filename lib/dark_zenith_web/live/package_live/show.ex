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
        <div class="space-y-2">
          <Layouts.breadcrumbs segments={[
            {"Repositories", ~p"/repos"},
            {@repository.slug, ~p"/repos/#{@repository.slug}"},
            {@name, nil}
          ]} />
          <.header>
            <span class="font-mono">{@name}</span>
            <:subtitle>
              All builds in
              <.link navigate={~p"/repos/#{@repository.slug}"} class="link">
                {@repository.name}
              </.link>
            </:subtitle>
          </.header>
        </div>

        <section :if={@install_command || @source_command}>
          <h2 class="text-lg font-semibold mb-2">Install</h2>
          <p class="text-sm text-base-content/70 mb-2">
            Assumes the repository is already configured on your system.
          </p>
          <.command_block :if={@install_command} id="install-cmd" command={@install_command} />
          <.command_block
            :if={@source_command}
            id="source-cmd"
            class="mt-2"
            command={@source_command}
          />
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-2">Builds</h2>
          <.table id="builds" rows={@packages} row_id={&"build-#{&1.id}"}>
            <:col :let={package} label="EVR" mono>
              <.link
                navigate={~p"/repos/#{@repository.slug}/package-versions/#{package.id}"}
                class="link"
              >
                {Packages.display_evr(package)}
              </.link>
            </:col>
            <:col :let={package} label="Arch" mono>{package.arch}</:col>
            <:col :let={package} label="Summary">
              <span class="block max-w-xs truncate">{package.summary}</span>
            </:col>
            <:col :let={package} label="Size" align={:right}>
              {format_bytes(package.size_package)}
            </:col>
            <:col :let={package} label="Uploaded">
              {Calendar.strftime(package.inserted_at, "%Y-%m-%d")}
            </:col>
          </.table>
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
