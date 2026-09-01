defmodule DarkZenithWeb.PackageLive.Version do
  @moduledoc """
  Package Version Detail (`GET /repos/:slug/package-versions/:id`) —
  full scalar metadata and counts, with each collection lazy-loaded as a
  paginated tab backed by the REST subresources; the initial LiveView state
  never contains all entries (DESIGN.md: Web Interface).
  """

  use DarkZenithWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias DarkZenith.Packages
  alias DarkZenith.Repositories

  @collections ~w(requires provides conflicts obsoletes recommends suggests supplements enhances files changelogs)
  @tab_page_size 50

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <div class="space-y-2">
          <Layouts.breadcrumbs segments={[
            {"Repositories", ~p"/repos"},
            {@repository.slug, ~p"/repos/#{@repository.slug}"},
            {@package.name, ~p"/repos/#{@repository.slug}/packages/#{@package.name}"},
            {"#{Packages.display_evr(@package)}.#{@package.arch}", nil}
          ]} />
          <.header>
            <span class="font-mono">{@package.name} {Packages.display_evr(@package)}</span>
            <:subtitle>
              <.link
                navigate={~p"/repos/#{@repository.slug}/packages/#{@package.name}"}
                class="link"
              >
                all {@package.name} builds
              </.link>
            </:subtitle>
          </.header>
        </div>

        <section class="grid grid-cols-2 gap-x-8 gap-y-1 text-sm">
          <div>
            <span class="font-semibold">Arch:</span>
            <span class="font-mono">{@package.arch}</span>
          </div>
          <div><span class="font-semibold">License:</span> {@package.license}</div>
          <div><span class="font-semibold">Size:</span> {@package.size_package} bytes</div>
          <div>
            <span class="font-semibold">Installed size:</span> {@package.size_installed} bytes
          </div>
          <div :if={@package.rpm_vendor}>
            <span class="font-semibold">Vendor:</span> {@package.rpm_vendor}
          </div>
          <div :if={@package.build_time}>
            <span class="font-semibold">Built:</span> {Calendar.strftime(
              @package.build_time,
              "%Y-%m-%d"
            )}
          </div>
          <div :if={@package.url} class="col-span-2">
            <span class="font-semibold">URL:</span>
            <a href={@package.url} class="link" rel="nofollow noopener">{@package.url}</a>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-1">Summary</h2>
          <p class="text-sm">{@package.summary}</p>
          <h2 class="text-lg font-semibold mb-1 mt-4">Description</h2>
          <pre class="text-sm whitespace-pre-wrap font-sans">{@package.description}</pre>
        </section>

        <section>
          <a href={@download_path} class="btn btn-primary" rel="nofollow">Download RPM</a>
        </section>

        <section>
          <div role="tablist" class="tabs tabs-border">
            <button
              :for={{collection, count} <- @counts}
              type="button"
              role="tab"
              class={["tab", @tab == collection && "tab-active"]}
              phx-click="tab"
              phx-value-collection={collection}
              id={"tab-#{collection}"}
              aria-selected={to_string(@tab == collection)}
            >
              {collection} ({count})
            </button>
          </div>

          <div :if={@tab} class="mt-4">
            <ul :if={@tab_entries != []} class="divide-y divide-base-300 text-sm">
              <li
                :for={{entry, index} <- Enum.with_index(@tab_entries)}
                id={"entry-#{index}"}
                class="py-1"
              >
                {render_entry(@tab, entry)}
              </li>
            </ul>
            <p :if={@tab_entries == []} class="text-sm text-base-content/70">No entries.</p>

            <div :if={@tab_pages > 1} class="mt-2 flex gap-2">
              <button
                :if={@tab_page > 1}
                class="btn btn-sm"
                phx-click="tab_page"
                phx-value-page={@tab_page - 1}
              >
                Previous
              </button>
              <span class="text-sm self-center">page {@tab_page} of {@tab_pages}</span>
              <button
                :if={@tab_page < @tab_pages}
                class="btn btn-sm"
                phx-click="tab_page"
                phx-value-page={@tab_page + 1}
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
  def mount(%{"slug" => slug, "id" => id}, _session, socket) do
    repository = Repositories.get_repository_by_slug(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    cond do
      repository && DarkZenith.Authorization.can_read?(user, repository) ->
        case package_with_counts(repository, id) do
          nil ->
            raise DarkZenithWeb.NotFoundError

          {package, counts} ->
            {:ok,
             socket
             |> assign(:repository, repository)
             |> assign(:package, package)
             |> assign(:counts, counts)
             |> assign(
               :download_path,
               "/repos/#{repository.slug}/packages/#{package.id}/" <>
                 "#{package.name}-#{package.version}-#{package.release}.#{package.arch}.rpm"
             )
             |> assign(:tab, nil)
             |> assign(:tab_entries, [])
             |> assign(:tab_page, 1)
             |> assign(:tab_pages, 0)}
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

  @impl true
  def handle_event("tab", %{"collection" => collection}, socket)
      when collection in @collections do
    {:noreply, load_tab(socket, collection, 1)}
  end

  def handle_event("tab_page", %{"page" => page}, socket) do
    {:noreply, load_tab(socket, socket.assigns.tab, String.to_integer(page))}
  end

  # The scalar row was loaded without the collection arrays; counts come from
  # jsonb lengths in SQL so the socket never holds full collections.
  defp package_with_counts(repository, id) do
    case Ecto.UUID.cast(id) do
      :error ->
        nil

      {:ok, uuid} ->
        result =
          DarkZenith.Repo.one(
            from p in DarkZenith.Packages.Package,
              where: p.id == ^uuid and p.repository_id == ^repository.id,
              select: {
                %DarkZenith.Packages.Package{
                  id: p.id,
                  repository_id: p.repository_id,
                  rpm_format: p.rpm_format,
                  name: p.name,
                  epoch: p.epoch,
                  version: p.version,
                  release: p.release,
                  arch: p.arch,
                  summary: p.summary,
                  description: p.description,
                  url: p.url,
                  license: p.license,
                  size_installed: p.size_installed,
                  size_package: p.size_package,
                  rpm_vendor: p.rpm_vendor,
                  build_time: p.build_time,
                  inserted_at: p.inserted_at
                },
                %{
                  "requires" => fragment("jsonb_array_length(?)", p.requires),
                  "provides" => fragment("jsonb_array_length(?)", p.provides),
                  "conflicts" => fragment("jsonb_array_length(?)", p.conflicts),
                  "obsoletes" => fragment("jsonb_array_length(?)", p.obsoletes),
                  "recommends" => fragment("jsonb_array_length(?)", p.recommends),
                  "suggests" => fragment("jsonb_array_length(?)", p.suggests),
                  "supplements" => fragment("jsonb_array_length(?)", p.supplements),
                  "enhances" => fragment("jsonb_array_length(?)", p.enhances),
                  "files" => fragment("jsonb_array_length(?)", p.files),
                  "changelogs" => fragment("jsonb_array_length(?)", p.changelogs)
                }
              }
          )

        case result do
          nil -> nil
          {package, counts} -> {package, Enum.map(@collections, &{&1, counts[&1]})}
        end
    end
  end

  # One page of one collection, via the same jsonb the REST subresources
  # serve, sliced in SQL so the LiveView never loads a full collection.
  defp load_tab(socket, collection, page) do
    package = socket.assigns.package
    count = socket.assigns.counts |> Enum.into(%{}) |> Map.fetch!(collection)
    pages = div(count + @tab_page_size - 1, @tab_page_size)
    page = max(min(page, max(pages, 1)), 1)
    offset = (page - 1) * @tab_page_size

    field = String.to_existing_atom(collection)

    # The same orderings as the REST subresources, applied before slicing:
    # dependency arrays by stored ordinal, files by path then ordinal, and
    # changelogs by timestamp descending then ordinal.
    entries =
      DarkZenith.Repo.one(
        case collection do
          "files" ->
            from p in DarkZenith.Packages.Package,
              where: p.id == ^package.id,
              select:
                fragment(
                  "(SELECT COALESCE(jsonb_agg(value), '[]'::jsonb) FROM (SELECT value FROM jsonb_array_elements(?) WITH ORDINALITY AS t(value, ord) ORDER BY value->>'path', ord OFFSET ? LIMIT ?) s)",
                  field(p, ^field),
                  ^offset,
                  ^@tab_page_size
                )

          "changelogs" ->
            from p in DarkZenith.Packages.Package,
              where: p.id == ^package.id,
              select:
                fragment(
                  "(SELECT COALESCE(jsonb_agg(value), '[]'::jsonb) FROM (SELECT value FROM jsonb_array_elements(?) WITH ORDINALITY AS t(value, ord) ORDER BY value->>'timestamp' DESC, ord OFFSET ? LIMIT ?) s)",
                  field(p, ^field),
                  ^offset,
                  ^@tab_page_size
                )

          _deps ->
            from p in DarkZenith.Packages.Package,
              where: p.id == ^package.id,
              select:
                fragment(
                  "(SELECT COALESCE(jsonb_agg(value), '[]'::jsonb) FROM (SELECT value FROM jsonb_array_elements(?) WITH ORDINALITY AS t(value, ord) ORDER BY ord OFFSET ? LIMIT ?) s)",
                  field(p, ^field),
                  ^offset,
                  ^@tab_page_size
                )
        end
      )

    socket
    |> assign(:tab, collection)
    |> assign(:tab_entries, entries)
    |> assign(:tab_page, page)
    |> assign(:tab_pages, pages)
  end

  defp render_entry(collection, entry)
       when collection in ~w(requires provides conflicts obsoletes recommends suggests supplements enhances) do
    version =
      if entry["op"] do
        release = if entry["release"], do: "-#{entry["release"]}", else: ""
        " #{entry["op"]} #{entry["epoch"]}:#{entry["version"]}#{release}"
      else
        ""
      end

    pre = if entry["pre"], do: " (pre)", else: ""
    entry["name"] <> version <> pre
  end

  defp render_entry("files", entry) do
    flags = if entry["flags"] == [], do: "", else: " [#{Enum.join(entry["flags"], ", ")}]"
    "#{entry["path"]} (#{entry["type"]})#{flags}"
  end

  defp render_entry("changelogs", entry) do
    "#{entry["timestamp"]} — #{entry["author"]}: #{entry["text"]}"
  end
end
