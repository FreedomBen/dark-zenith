defmodule DarkZenithWeb.RepositoryLive.Show do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.RepoFile

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-8">
        <div class="flex items-center justify-between">
          <.header>
            {@repository.name}
            <span :if={!@repository.is_public} class="badge badge-ghost align-middle ml-2">
              private
            </span>
            <:subtitle>{@repository.description}</:subtitle>
          </.header>
          <div :if={@manager?} class="flex gap-2">
            <.link navigate={~p"/repos/#{@repository.slug}/settings"} class="btn btn-ghost">
              Settings
            </.link>
            <.link navigate={~p"/repos/#{@repository.slug}/upload"} class="btn btn-primary">
              Upload RPM
            </.link>
          </div>
        </div>

        <section>
          <h2 class="text-lg font-semibold mb-2">Setup instructions</h2>

          <p class="text-sm mb-2">
            Save this as <code>/etc/yum.repos.d/dark-zenith-{@repository.slug}.repo</code>:
          </p>
          <pre class="bg-base-200 rounded-lg p-4 text-sm overflow-x-auto"><code>{@repo_file}</code></pre>

          <div :if={!@repository.is_public} class="text-sm mt-2 space-y-1">
            <p>
              Replace <code>&lt;api-key&gt;</code>
              with one of your API keys carrying <code>repo:read</code>, then restrict the file since it embeds the key:
            </p>
            <pre class="bg-base-200 rounded-lg p-4 overflow-x-auto"><code>sudo chmod 600 /etc/yum.repos.d/dark-zenith-{@repository.slug}.repo</code></pre>
          </div>

          <div :if={@repository.is_public} class="mt-4 space-y-2 text-sm">
            <p>Or add it with one command:</p>
            <pre class="bg-base-200 rounded-lg p-4 overflow-x-auto"><code>dnf config-manager --add-repo {@base_url}/repos/{@repository.slug}/dark-zenith.repo</code></pre>
            <p>DNF 5:</p>
            <pre class="bg-base-200 rounded-lg p-4 overflow-x-auto"><code>dnf5 config-manager addrepo --from-repofile={@base_url}/repos/{@repository.slug}/dark-zenith.repo</code></pre>
            <details class="mt-2">
              <summary class="cursor-pointer">
                Authenticated access (recommended for higher rate limits)
              </summary>
              <pre class="bg-base-200 rounded-lg p-4 mt-2 overflow-x-auto"><code>{@authenticated_repo_file}</code></pre>
            </details>
          </div>

          <div :if={@repository.gpg_key_fingerprint} class="mt-4 text-sm">
            <p>Import the repository signing key:</p>
            <pre class="bg-base-200 rounded-lg p-4 overflow-x-auto"><code>sudo rpmkeys --import {@base_url}/repos/{@repository.slug}/RPM-GPG-KEY</code></pre>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-2">Packages</h2>

          <form id="package-search-form" phx-change="search_packages" class="mb-3 flex gap-2">
            <input
              type="text"
              name="q"
              value={@package_q}
              placeholder="Search name or summary"
              phx-debounce="300"
              class="input input-bordered input-sm grow"
            />
            <select name="sort" class="select select-bordered select-sm w-44">
              <option value="" selected={@package_sort == nil}>Name</option>
              <option value="version" selected={@package_sort == "version"}>Version (EVR)</option>
              <option value="arch" selected={@package_sort == "arch"}>Arch</option>
              <option value="-inserted_at" selected={@package_sort == "-inserted_at"}>
                Newest
              </option>
            </select>
          </form>

          <div
            :if={@packages == []}
            class="text-base-content/60 text-sm py-8 text-center border border-dashed border-base-300 rounded-lg"
          >
            No packages{if @package_q != "", do: " match", else: " yet"}.
          </div>

          <div :if={@packages != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>EVR</th>
                  <th>Arch</th>
                  <th>Summary</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={package <- @packages} id={"package-#{package.id}"}>
                  <td>
                    <.link
                      navigate={~p"/repos/#{@repository.slug}/packages/#{package.name}"}
                      class="link"
                    >
                      {package.name}
                    </.link>
                  </td>
                  <td class="font-mono">
                    <.link
                      navigate={~p"/repos/#{@repository.slug}/package-versions/#{package.id}"}
                      class="link"
                    >
                      {DarkZenith.Packages.display_evr(package)}
                    </.link>
                  </td>
                  <td>{package.arch}</td>
                  <td class="max-w-xs truncate">{package.summary}</td>
                </tr>
              </tbody>
            </table>

            <div :if={@package_pages > 1} class="mt-2 flex gap-2 items-center text-sm">
              <button
                :if={@package_page > 1}
                class="btn btn-sm"
                phx-click="package_page"
                phx-value-page={@package_page - 1}
              >
                Previous
              </button>
              <span>page {@package_page} of {@package_pages}</span>
              <button
                :if={@package_page < @package_pages}
                class="btn btn-sm"
                phx-click="package_page"
                phx-value-page={@package_page + 1}
              >
                Next
              </button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    repository = Repositories.get_repository_by_slug(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    cond do
      repository && accessible?(repository, user) ->
        base_url = DarkZenithWeb.Endpoint.url()

        {:ok,
         socket
         |> assign(:repository, repository)
         |> assign(:manager?, manager?(repository, user))
         |> assign(:base_url, base_url)
         |> assign(:repo_file, RepoFile.render(repository, base_url))
         |> assign(
           :authenticated_repo_file,
           RepoFile.render(repository, base_url, credentials: :with_placeholders)
         )
         |> assign(:package_q, "")
         |> assign(:package_sort, nil)
         |> load_packages(1)}

      is_nil(user) ->
        # Anonymous requests for private and nonexistent slugs redirect to the
        # login page without revealing which case applies.
        {:ok,
         socket
         |> put_flash(:error, "You must log in to access this page.")
         |> redirect(to: ~p"/users/log-in")}

      true ->
        raise DarkZenithWeb.NotFoundError
    end
  end

  @valid_sorts ~w(version -version arch -arch inserted_at -inserted_at name -name)

  @impl true
  def handle_event("search_packages", params, socket) do
    sort = if params["sort"] in @valid_sorts, do: params["sort"], else: nil

    {:noreply,
     socket
     |> assign(:package_q, String.slice(params["q"] || "", 0, 256))
     |> assign(:package_sort, sort)
     |> load_packages(1)}
  end

  def handle_event("package_page", %{"page" => page}, socket) do
    {:noreply, load_packages(socket, String.to_integer(page))}
  end

  @per_page 50

  defp load_packages(socket, page) do
    repository = socket.assigns.repository
    q = String.trim(socket.assigns.package_q)

    sort =
      case socket.assigns.package_sort do
        nil -> nil
        "-" <> field -> {String.to_existing_atom(field), :desc}
        field -> {String.to_existing_atom(field), :asc}
      end

    query =
      DarkZenith.Packages.list_query(repository.id, q: if(q == "", do: nil, else: q), sort: sort)

    {packages, total} = DarkZenithWeb.Api.Pagination.paginate(query, page, @per_page)

    socket
    |> assign(:packages, packages)
    |> assign(:package_page, page)
    |> assign(:package_pages, div(total + @per_page - 1, @per_page))
  end

  defp accessible?(repository, user) do
    DarkZenith.Authorization.can_read?(user, repository)
  end

  defp manager?(repository, user) do
    DarkZenith.Authorization.can_manage?(user, repository)
  end
end
