defmodule DarkZenithWeb.UploadHistoryComponents do
  @moduledoc """
  The Upload History row layout shared by the repository detail page and
  the admin Uploads tab (docs/DESIGN_UI.md — Repository detail: Upload
  History; Admin): the status badge for a live intent status, a recorded
  outcome, or the awaiting-reconciliation `Unknown` row; the outcome
  segmented control; the dense paginated table; and the page links.
  Behavior follows `DESIGN.md` (Repository Detail — Upload History; Admin —
  Upload records).
  """

  use Phoenix.Component
  use DarkZenithWeb, :verified_routes

  import DarkZenithWeb.CoreComponents

  alias DarkZenith.Uploads.FailureReason

  @outcome_labels [
    {"in_flight", "In flight"},
    {"succeeded", "Succeeded"},
    {"failed", "Failed"},
    {"expired", "Expired"},
    {"canceled", "Canceled"}
  ]

  @cancelable ~w(awaiting_upload queued processing preview_ready)

  @doc """
  Renders the upload record table. `live_repositories` maps a
  `repository_id` to its current slug only while that repository exists;
  `show_repository` adds the admin view's mono slug column, linked only
  for a live repository; `actions` offers the initiator-only upload-page
  link and cancel action, which the read-only admin view leaves out.
  """
  attr :id, :string, required: true
  attr :records, :list, required: true
  attr :current_user, :map, required: true
  attr :live_repositories, :map, required: true
  attr :show_repository, :boolean, default: false
  attr :actions, :boolean, default: false

  def upload_table(assigns) do
    ~H"""
    <.table id={@id} rows={@records} row_id={&"upload-record-#{&1.id}"}>
      <:col :let={record} :if={@show_repository} label="Repository" mono>
        <.link
          :if={@live_repositories[record.repository_id]}
          navigate={~p"/repos/#{@live_repositories[record.repository_id]}"}
          class="link"
        >
          {record.repository_slug}
        </.link>
        <span :if={!@live_repositories[record.repository_id]} class="text-base-content/70">
          {record.repository_slug}
        </span>
      </:col>
      <:col :let={record} label="File" mono>
        <.link
          :if={@actions && own_live?(record, @current_user)}
          navigate={~p"/repos/#{record.repository_slug}/upload?intent=#{record.intent_id}"}
          class="link"
        >
          {record.original_filename}
        </.link>
        <span :if={!(@actions && own_live?(record, @current_user))}>
          {record.original_filename}
        </span>
        <div :if={record.outcome == "succeeded" && record.nevra} class="text-xs">
          <.link
            :if={@live_repositories[record.repository_id]}
            navigate={
              ~p"/repos/#{@live_repositories[record.repository_id]}/package-versions/#{record.package_id}"
            }
            class="link text-base-content/70"
          >
            {record.nevra}
          </.link>
          <span :if={!@live_repositories[record.repository_id]} class="text-base-content/70">
            {record.nevra}
          </span>
        </div>
        <div :if={record.outcome == "failed"} class="text-xs text-base-content/70">
          {record.error_code}<span :if={reason(record)}> · {reason(record)}</span>
        </div>
      </:col>
      <:col :let={record} label="Initiator" mono>
        {record.user_email}
        <span :if={own?(record, @current_user)} class="badge badge-ghost badge-xs ml-1">you</span>
      </:col>
      <:col :let={record} label="Source">{mode_label(record.mode)}</:col>
      <:col :let={record} label="Size" align={:right} mono>
        {format_bytes(record.final_size || record.declared_size)}
      </:col>
      <:col :let={record} label="Status"><.status_badge record={record} /></:col>
      <:col :let={record} label="Started">
        <span class="whitespace-nowrap text-base-content/70">{format_time(record.started_at)}</span>
      </:col>
      <:col :let={record} label="Finished">
        <span class="whitespace-nowrap text-base-content/70">{format_time(record.finished_at)}</span>
      </:col>
      <:action :let={record} :if={@actions}>
        <button
          :if={cancelable?(record, @current_user)}
          id={"cancel-upload-#{record.id}"}
          class="btn btn-ghost btn-xs text-error"
          phx-click="cancel_upload"
          phx-value-id={record.intent_id}
          data-confirm="Cancel this upload? Its staged transfer is discarded."
        >
          Cancel
        </button>
      </:action>
    </.table>
    """
  end

  @doc """
  The status badge: a surviving intent's live status for an `in_flight`
  row, `Unknown` for one awaiting reconciliation, and the recorded outcome
  otherwise.
  """
  attr :record, :map, required: true

  def status_badge(assigns) do
    ~H"""
    <.badge variant={status_variant(@record)} class="badge-sm" />
    """
  end

  @doc "The badge variant for a record's displayed status."
  def status_variant(%{outcome: "in_flight", live_status: status}) when status in @cancelable,
    do: String.to_existing_atom(status)

  def status_variant(%{outcome: "in_flight"}), do: :unknown

  def status_variant(%{outcome: outcome})
      when outcome in ~w(succeeded failed expired canceled),
      do: String.to_existing_atom(outcome)

  @doc """
  The outcome segmented control: All plus one segment per outcome, as
  patch links. `selected` is `nil` for All, one outcome for that segment,
  or anything else (a comma-separated subset) to select no segment.
  """
  attr :id, :string, default: "outcome-filter"
  attr :selected, :any, required: true
  attr :path, :any, required: true, doc: "function from an outcome (or nil for All) to a path"

  def outcome_filter(assigns) do
    assigns = assign(assigns, :labels, @outcome_labels)

    ~H"""
    <nav id={@id} aria-label="Outcome filter" class="join">
      <.link
        patch={@path.(nil)}
        class={["btn btn-xs join-item", is_nil(@selected) && "btn-active"]}
        aria-current={is_nil(@selected) && "true"}
      >
        All
      </.link>
      <.link
        :for={{value, label} <- @labels}
        patch={@path.(value)}
        class={["btn btn-xs join-item", @selected == value && "btn-active"]}
        aria-current={@selected == value && "true"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  @doc "Previous / page N of M / Next as patch links; renders nothing for one page."
  attr :id, :string, default: "upload-pagination"
  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :path, :any, required: true, doc: "function from a page number to a path"

  def pagination(assigns) do
    ~H"""
    <div :if={@pages > 1} id={@id} class="flex items-center gap-2 text-sm">
      <.link :if={@page > 1} patch={@path.(@page - 1)} class="btn btn-sm">Previous</.link>
      <span>page {@page} of {@pages}</span>
      <.link :if={@page < @pages} patch={@path.(@page + 1)} class="btn btn-sm">Next</.link>
    </div>
    """
  end

  @doc "The segment an outcome filter selects: All, one outcome, or none."
  def selected_segment(nil), do: nil
  def selected_segment([one]), do: one
  def selected_segment(_subset), do: :none

  ## Helpers

  defp own?(record, %{id: user_id}), do: record.user_id == user_id
  defp own?(_record, _user), do: false

  # The upload page reattaches only to the viewer's own live intents.
  defp own_live?(record, user) do
    record.outcome == "in_flight" and record.live_status in @cancelable and own?(record, user)
  end

  defp cancelable?(record, user), do: own_live?(record, user)

  defp reason(record) do
    if record.error_detail && FailureReason.message(record.error_detail),
      do: record.error_detail,
      else: nil
  end

  defp mode_label("web_preview"), do: "web"
  defp mode_label("api"), do: "API"
  defp mode_label(other), do: other

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
