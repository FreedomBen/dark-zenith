defmodule DarkZenithWeb.RepositoryLive.Show do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.RepoFile

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <div class="space-y-2">
          <Layouts.breadcrumbs segments={[
            {"Repositories", ~p"/repos"},
            {@repository.slug, nil}
          ]} />
          <.header>
            {@repository.name}
            <.badge :if={!@repository.is_public} variant={:private} class="align-middle ml-2" />
            <:subtitle>{@repository.description}</:subtitle>
            <:actions :if={@manager?}>
              <div class="flex gap-2">
                <.link navigate={~p"/repos/#{@repository.slug}/settings"} class="btn btn-ghost">
                  Settings
                </.link>
                <.link navigate={~p"/repos/#{@repository.slug}/upload"} class="btn btn-primary">
                  Upload RPM
                </.link>
              </div>
            </:actions>
          </.header>
        </div>

        <section :if={@repository.is_public}>
          <h2 class="text-lg font-semibold mb-2">Setup instructions</h2>

          <div role="tablist" class="tabs tabs-border mb-3">
            <button
              :for={
                {tab, label} <- [{"dnf5", "DNF 5"}, {"dnf4", "DNF 4"}, {"repo-file", ".repo file"}]
              }
              type="button"
              role="tab"
              id={"setup-tab-#{tab}"}
              class={["tab", @setup_tab == tab && "tab-active"]}
              aria-selected={to_string(@setup_tab == tab)}
              phx-click="setup_tab"
              phx-value-tab={tab}
            >
              {label}
            </button>
          </div>

          <div :if={@setup_tab == "dnf5"} class="space-y-2 text-sm">
            <p>Add the repository with one command:</p>
            <.command_block
              id="dnf5-addrepo"
              eyebrow="DNF 5"
              command={"dnf5 config-manager addrepo --from-repofile=#{repo_file_url(@base_url, @repository)}"}
            />
          </div>

          <div :if={@setup_tab == "dnf4"} class="space-y-2 text-sm">
            <p>Add the repository with one command:</p>
            <.command_block
              id="dnf4-addrepo"
              eyebrow="DNF 4"
              command={"dnf config-manager --add-repo #{repo_file_url(@base_url, @repository)}"}
            />
          </div>

          <div :if={@setup_tab == "repo-file"} class="space-y-2 text-sm">
            <p>
              Save this as <code>/etc/yum.repos.d/dark-zenith-{@repository.slug}.repo</code>:
            </p>
            <.command_block id="repo-file" command={@repo_file} />
            <details class="mt-2">
              <summary class="cursor-pointer">
                Authenticated access (recommended for higher rate limits)
              </summary>
              <.command_block id="auth-repo-file" class="mt-2" command={@authenticated_repo_file} />
            </details>
          </div>

          <div :if={@repository.gpg_key_fingerprint} class="mt-4 text-sm">
            <p class="mb-2">Import the repository signing key:</p>
            <.command_block
              id="gpg-import"
              command={"sudo rpmkeys --import #{gpg_key_url(@base_url, @repository)}"}
            />
          </div>
        </section>

        <section :if={!@repository.is_public}>
          <h2 class="text-lg font-semibold mb-2">Setup instructions</h2>

          <p class="text-sm mb-2">
            Save this as <code>/etc/yum.repos.d/dark-zenith-{@repository.slug}.repo</code>:
          </p>
          <.command_block id="repo-file" command={@repo_file} />

          <div class="text-sm mt-2 space-y-1">
            <p>
              Replace <code>&lt;api-key&gt;</code>
              with one of your API keys carrying <code>repo:read</code>, then restrict the file since it embeds the key:
            </p>
            <.command_block
              id="chmod-repo-file"
              command={"sudo chmod 600 /etc/yum.repos.d/dark-zenith-#{@repository.slug}.repo"}
            />
            <div :if={!@has_suitable_key?} class="alert alert-warning alert-soft mt-2">
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
              <span>
                You have no active API key with <code>repo:read</code>.
                <.link navigate={~p"/users/settings"} class="link font-semibold">
                  Create one in account settings
                </.link>
                first — the plaintext is shown exactly once at creation.
              </span>
            </div>
          </div>

          <div :if={@repository.gpg_key_fingerprint} class="mt-4 text-sm">
            <p class="mb-2">
              Import the repository signing key. The key URL requires credentials,
              so curl prompts for your API key (it never appears in the command
              or a file):
            </p>
            <.command_block
              id="gpg-import-private"
              command={"curl --fail --user token #{gpg_key_url(@base_url, @repository)} | sudo rpmkeys --import -"}
            />
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-2">Packages</h2>

          <form id="package-search-form" phx-change="search_packages" class="mb-3">
            <input
              type="text"
              name="q"
              value={@package_q}
              placeholder="Search name or summary"
              phx-debounce="300"
              class="input input-bordered input-sm w-full sm:w-80"
            />
          </form>

          <Layouts.empty_state :if={@packages == []}>
            No packages{if @package_q != "", do: " match", else: " yet"}.
            <:action :if={@manager? && @package_q == ""}>
              <.link
                navigate={~p"/repos/#{@repository.slug}/upload"}
                class="btn btn-outline btn-sm"
              >
                Upload the first RPM
              </.link>
            </:action>
          </Layouts.empty_state>

          <div :if={@packages != []}>
            <.table
              id="packages"
              rows={@packages}
              row_id={&"package-#{&1.id}"}
              sort={@package_sort}
              sort_event="sort_packages"
            >
              <:col :let={package} label="Name" sort="name" mono>
                <.link
                  navigate={~p"/repos/#{@repository.slug}/packages/#{package.name}"}
                  class="link"
                >
                  {package.name}
                </.link>
              </:col>
              <:col :let={package} label="EVR" sort="version" mono>
                <.link
                  navigate={~p"/repos/#{@repository.slug}/package-versions/#{package.id}"}
                  class="link"
                >
                  {DarkZenith.Packages.display_evr(package)}
                </.link>
              </:col>
              <:col :let={package} label="Arch" sort="arch" mono>{package.arch}</:col>
              <:col :let={package} label="Summary">
                <span class="block max-w-xs truncate">{package.summary}</span>
              </:col>
              <:col :let={package} label="Uploaded" sort="inserted_at">
                {Calendar.strftime(package.inserted_at, "%Y-%m-%d")}
              </:col>
            </.table>

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
         |> assign(:has_suitable_key?, suitable_key?(repository, user))
         |> assign(:setup_tab, "dnf5")
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
  @setup_tabs ~w(dnf5 dnf4 repo-file)

  @impl true
  def handle_event("setup_tab", %{"tab" => tab}, socket) when tab in @setup_tabs do
    {:noreply, assign(socket, :setup_tab, tab)}
  end

  def handle_event("search_packages", params, socket) do
    {:noreply,
     socket
     |> assign(:package_q, String.slice(params["q"] || "", 0, 256))
     |> load_packages(1)}
  end

  def handle_event("sort_packages", %{"sort" => sort}, socket) when sort in @valid_sorts do
    {:noreply,
     socket
     |> assign(:package_sort, sort)
     |> load_packages(1)}
  end

  # Out-of-vocabulary sort values (a crafted event) are ignored.
  def handle_event("sort_packages", _params, socket), do: {:noreply, socket}

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

  # Whether the viewer holds an active repo:read API key for the private
  # setup snippet; if not, the page prompts them to create one (DESIGN.md:
  # Repository Detail). Public pages never prompt.
  defp suitable_key?(%{is_public: true}, _user), do: true
  defp suitable_key?(_repository, nil), do: false

  defp suitable_key?(_repository, user) do
    DarkZenith.Accounts.has_usable_api_key?(user, "repo:read")
  end

  defp manager?(repository, user) do
    DarkZenith.Authorization.can_manage?(user, repository)
  end

  defp repo_file_url(base_url, repository) do
    "#{base_url}/repos/#{repository.slug}/dark-zenith.repo"
  end

  defp gpg_key_url(base_url, repository) do
    "#{base_url}/repos/#{repository.slug}/RPM-GPG-KEY"
  end
end
