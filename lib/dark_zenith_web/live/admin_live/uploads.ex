defmodule DarkZenithWeb.AdminLive.Uploads do
  @moduledoc """
  The instance-wide, read-only upload-record view (DESIGN.md: Admin —
  Upload records): every Package Upload Record, kept after its repository,
  package, or initiator is gone. `repository` (slug snapshot), `initiator`
  (email snapshot, normalized), the `outcome` filter, and the page are held
  in the URL. The view never auto-refreshes; the repository's own Upload
  History section remains the live monitor.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Uploads.Records
  alias DarkZenithWeb.{AdminComponents, UploadHistoryComponents}

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <AdminComponents.admin_page
        active="uploads"
        subtitle="Every package upload record, kept after its repository, package, or initiator is gone."
      >
        <div class="flex flex-wrap items-center gap-3">
          <form id="upload-filters" phx-change="filter" class="flex flex-wrap gap-2">
            <label class="sr-only" for="upload-filter-repository">Repository slug</label>
            <input
              type="text"
              id="upload-filter-repository"
              name="repository"
              value={@repository}
              placeholder="Repository slug"
              phx-debounce="300"
              class="input input-sm w-56 font-mono"
            />
            <label class="sr-only" for="upload-filter-initiator">Initiator email</label>
            <input
              type="text"
              id="upload-filter-initiator"
              name="initiator"
              value={@initiator}
              placeholder="Initiator email"
              phx-debounce="300"
              class="input input-sm w-56 font-mono"
            />
          </form>
          <UploadHistoryComponents.outcome_filter
            selected={@selected}
            path={&admin_path(@repository, @initiator, &1, 1)}
          />
        </div>

        <Layouts.empty_state :if={@records == []}>
          {if @filtered?, do: "No upload records match the filters.", else: "No upload records yet."}
        </Layouts.empty_state>

        <UploadHistoryComponents.upload_table
          :if={@records != []}
          id="admin-uploads"
          records={@records}
          current_user={@current_scope.user}
          live_repositories={@live_repositories}
          show_repository
        />

        <UploadHistoryComponents.pagination
          page={@page}
          pages={@pages}
          path={&admin_path(@repository, @initiator, @outcome_param, &1)}
        />
      </AdminComponents.admin_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:repository, "")
     |> assign(:initiator, "")
     |> assign(:outcome_param, nil)
     |> assign(:selected, nil)
     |> assign(:filtered?, false)
     |> assign(:records, [])
     |> assign(:live_repositories, %{})
     |> assign(:page, 1)
     |> assign(:pages, 0)}
  end

  # All three filters and the page resolve from the URL.
  @impl true
  def handle_params(params, _uri, socket) do
    repository = param_string(params["repository"], 64)
    initiator = param_string(params["initiator"], 160)

    {outcomes, outcome_param} =
      case Records.parse_outcome_filter(params["outcome"]) do
        {:ok, outcomes} -> {outcomes, params["outcome"]}
        {:error, _message} -> {nil, nil}
      end

    page = parse_page(params["page"])

    {records, total} =
      Records.list_admin_records(
        repository: normalize(repository),
        initiator: normalize(initiator),
        outcomes: outcomes,
        page: page,
        per_page: @per_page
      )

    {:noreply,
     socket
     |> assign(:repository, repository)
     |> assign(:initiator, initiator)
     |> assign(:outcome_param, outcome_param)
     |> assign(:selected, UploadHistoryComponents.selected_segment(outcomes))
     |> assign(
       :filtered?,
       normalize(repository) != nil or normalize(initiator) != nil or outcomes != nil
     )
     |> assign(:records, records)
     |> assign(
       :live_repositories,
       Records.live_repositories(Enum.map(records, & &1.repository_id))
     )
     |> assign(:page, page)
     |> assign(:pages, div(total + @per_page - 1, @per_page))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         admin_path(
           param_string(params["repository"], 64),
           param_string(params["initiator"], 160),
           socket.assigns.outcome_param,
           1
         )
     )}
  end

  defp param_string(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp param_string(_value, _max), do: ""

  # Slugs and emails are matched exactly against their snapshots after the
  # same trim-and-downcase normalization every email input receives.
  defp normalize(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp admin_path(repository, initiator, outcome, page) do
    query =
      [repository: repository, initiator: initiator, outcome: outcome, page: page]
      |> Enum.reject(fn {_key, value} -> value in [nil, "", 1] end)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    if query == %{}, do: ~p"/admin/uploads", else: ~p"/admin/uploads?#{query}"
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page >= 1 -> page
      _ -> 1
    end
  end

  defp parse_page(_value), do: 1
end
