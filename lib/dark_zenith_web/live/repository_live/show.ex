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
            <button
              class="btn btn-primary"
              disabled
              title="Package upload arrives with the upload pipeline"
            >
              Upload RPM
            </button>
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
          <div class="text-base-content/60 text-sm py-8 text-center border border-dashed border-base-300 rounded-lg">
            No packages yet.
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
         )}

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

  defp accessible?(repository, user) do
    repository.is_public or manager?(repository, user)
  end

  defp manager?(_repository, nil), do: false

  defp manager?(repository, user) do
    user.is_admin or user.id == repository.user_id
  end
end
