defmodule DarkZenithWeb.SearchLive.Index do
  @moduledoc """
  Instance-wide search results page (`GET /search`) — DESIGN.md: Web
  Interface — Search; docs/DESIGN_UI.md: Page notes — Search results.

  Execution is submit-driven: the query (and package page) lives in the URL,
  runs on page load and on query submit, and never per keystroke. Visibility
  matches repository browsing; results are filtered, never masked.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Packages
  alias DarkZenith.Repositories
  alias DarkZenithWeb.Api.Pagination

  # The repository group shows the first 20 matches and does not paginate;
  # the package group pages 50 rows with the page in the URL (DESIGN.md:
  # Search result groups).
  @repo_group_limit 20
  @per_page 50
  @q_max 256
  @max_page 10_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <.header>
          Search
          <:subtitle>Packages and repositories you can browse, instance-wide</:subtitle>
        </.header>

        <form id="search-form" phx-submit="search" class="flex max-w-xl gap-2">
          <label class="sr-only" for="search-q">Search packages</label>
          <input
            type="search"
            id="search-q"
            name="q"
            value={@q}
            placeholder="Search packages…"
            maxlength={@q_max}
            class="input input-bordered w-full"
          />
          <button type="submit" class="btn btn-primary">Search</button>
        </form>

        <p :if={@mode == :error} class="flex items-center gap-2 text-sm text-error">
          <.icon name="hero-exclamation-circle-micro" class="size-5 shrink-0" />
          Search queries are limited to {@q_max} characters.
        </p>

        <p :if={@mode == :prompt} class="text-sm text-base-content/70">
          Search for packages by name or summary, and repositories by slug, name, or
          description.
        </p>

        <%= if @mode == :results do %>
          <Layouts.empty_state :if={@repo_total == 0 and @package_total == 0}>
            No repositories or packages match “{String.trim(@q)}”.
          </Layouts.empty_state>

          <section :if={@repo_total > 0}>
            <h2 class="mb-2 text-lg font-semibold">Repositories</h2>

            <.table id="search-repositories" rows={@repositories} row_id={&"search-repo-#{&1.id}"}>
              <:col :let={repository} label="Slug" mono>
                <.link navigate={~p"/repos/#{repository.slug}"} class="link">
                  {repository.slug}
                </.link>
              </:col>
              <:col :let={repository} label="Name">{repository.name}</:col>
              <:col :let={repository} label="Description">
                <span class="block max-w-md truncate text-base-content/70">
                  {repository.description}
                </span>
              </:col>
              <:col :let={repository} label="Visibility">
                <.badge
                  variant={if repository.is_public, do: :public, else: :private}
                  class="badge-sm"
                />
              </:col>
            </.table>

            <p :if={@repo_total > @repo_group_limit} class="mt-2 text-sm text-base-content/60">
              Showing the first {@repo_group_limit} of {@repo_total} matching repositories —
              refine the query to narrow them.
            </p>
          </section>

          <section :if={@package_total > 0}>
            <h2 class="mb-2 text-lg font-semibold">Packages</h2>

            <.table
              :if={@packages != []}
              id="search-packages"
              rows={@packages}
              row_id={&"search-package-#{&1.package.id}"}
            >
              <:col :let={row} label="Name" mono>
                <.link
                  navigate={~p"/repos/#{row.repository.slug}/package-versions/#{row.package.id}"}
                  class="link"
                >
                  {row.package.name}
                </.link>
              </:col>
              <:col :let={row} label="EVR" mono>
                <.link
                  navigate={~p"/repos/#{row.repository.slug}/package-versions/#{row.package.id}"}
                  class="link"
                >
                  {Packages.display_evr(row.package)}
                </.link>
              </:col>
              <:col :let={row} label="Arch" mono>{row.package.arch}</:col>
              <:col :let={row} label="Repository" mono>
                <.link navigate={~p"/repos/#{row.repository.slug}"} class="link">
                  {row.repository.slug}
                </.link>
              </:col>
              <:col :let={row} label="Summary">
                <span class="block max-w-xs truncate">{row.package.summary}</span>
              </:col>
            </.table>

            <div :if={@package_pages > 1} class="mt-2 flex items-center gap-2 text-sm">
              <button
                :if={@package_page > 1}
                class="btn btn-sm"
                phx-click="page"
                phx-value-page={@package_page - 1}
              >
                Previous
              </button>
              <span>page {@package_page} of {@package_pages}</span>
              <button
                :if={@package_page < @package_pages}
                class="btn btn-sm"
                phx-click="page"
                phx-value-page={@package_page + 1}
              >
                Next
              </button>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:q_max, @q_max)
     |> assign(:repo_group_limit, @repo_group_limit)}
  end

  # The query lives in the URL, so loads, submits, pagination, and history
  # navigation all resolve here.
  @impl true
  def handle_params(params, _uri, socket) do
    raw_q = if is_binary(params["q"]), do: params["q"], else: ""
    q = String.trim(raw_q)
    socket = assign(socket, :q, raw_q)

    cond do
      q == "" ->
        {:noreply, assign(socket, :mode, :prompt)}

      String.length(q) > @q_max ->
        {:noreply, assign(socket, :mode, :error)}

      true ->
        {:noreply, socket |> assign(:mode, :results) |> run_search(q, parse_page(params["page"]))}
    end
  end

  @impl true
  def handle_event("search", params, socket) do
    case String.trim(params["q"] || "") do
      "" -> {:noreply, push_patch(socket, to: ~p"/search")}
      q -> {:noreply, push_patch(socket, to: ~p"/search?q=#{q}")}
    end
  end

  def handle_event("page", %{"page" => page}, socket) do
    q = String.trim(socket.assigns.q)
    {:noreply, push_patch(socket, to: ~p"/search?q=#{q}&page=#{page}")}
  end

  defp run_search(socket, q, page) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    {repositories, repo_total} =
      user
      |> Repositories.visible_repositories_query(q: q)
      |> Pagination.paginate(1, @repo_group_limit)

    {packages, package_total} =
      user
      |> Packages.search_query(q: q)
      |> Pagination.paginate(page, @per_page)

    socket
    |> assign(:repositories, repositories)
    |> assign(:repo_total, repo_total)
    |> assign(:packages, packages)
    |> assign(:package_total, package_total)
    |> assign(:package_page, page)
    |> assign(:package_pages, div(package_total + @per_page - 1, @per_page))
  end

  # Web pages are forgiving about the page parameter: anything that is not a
  # usable page number loads page 1 (the API surface stays strict).
  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {page, ""} when page >= 1 -> min(page, @max_page)
      _ -> 1
    end
  end

  defp parse_page(_raw), do: 1
end
