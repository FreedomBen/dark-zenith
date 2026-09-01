defmodule DarkZenithWeb.AdminLive.Jobs do
  @moduledoc """
  Background-job intervention view (DESIGN.md: Admin): failed, exhausted,
  and cancelled Oban jobs with retry/discard actions. Retrying an Oban row
  alone never changes durable application state — the durable state
  machines fence their own workers.
  """

  use DarkZenithWeb, :live_view

  import Ecto.Query

  alias DarkZenith.Repo
  alias DarkZenithWeb.AdminComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <AdminComponents.admin_page
        active="jobs"
        subtitle="Retrying a row re-runs the worker; the durable upload/signing state machines still fence stale attempts."
      >
        <Layouts.empty_state :if={@jobs == []}>
          No failed or exhausted jobs.
        </Layouts.empty_state>

        <.table :if={@jobs != []} id="admin-jobs" rows={@jobs} row_id={&"job-#{&1.id}"}>
          <:col :let={job} label="Worker">
            <span class="font-mono text-xs">{job.worker}</span>
          </:col>
          <:col :let={job} label="Queue" mono>{job.queue}</:col>
          <:col :let={job} label="State">
            <span class={["badge badge-soft badge-sm", state_badge(job.state)]}>{job.state}</span>
          </:col>
          <:col :let={job} label="Attempt" align={:right}>
            <span class="font-mono">{job.attempt}/{job.max_attempts}</span>
          </:col>
          <:col :let={job} label="Last error">
            <span class="block max-w-md truncate font-mono text-xs">{last_error(job)}</span>
          </:col>
          <:action :let={job}>
            <span class="flex justify-end gap-1 whitespace-nowrap">
              <button
                id={"retry-job-#{job.id}"}
                class="btn btn-ghost btn-xs"
                phx-click="retry"
                phx-value-id={job.id}
              >
                Retry
              </button>
              <button
                :if={job.state != "cancelled"}
                id={"cancel-job-#{job.id}"}
                class="btn btn-ghost btn-xs text-error"
                phx-click="cancel"
                phx-value-id={job.id}
                data-confirm="Cancel this job?"
              >
                Cancel
              </button>
            </span>
          </:action>
        </.table>
      </AdminComponents.admin_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, reload(socket)}
  end

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    Oban.retry_job(String.to_integer(id))
    {:noreply, socket |> reload() |> put_flash(:info, "Job scheduled for retry.")}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Oban.cancel_job(String.to_integer(id))
    {:noreply, socket |> reload() |> put_flash(:info, "Job cancelled.")}
  end

  defp reload(socket) do
    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.state in ["retryable", "discarded", "cancelled"],
          order_by: [desc: j.id],
          limit: 100
      )

    assign(socket, :jobs, jobs)
  end

  defp last_error(%{errors: [%{"error" => error} | _]}), do: error
  defp last_error(%{errors: [error | _]}) when is_map(error), do: inspect(error)
  defp last_error(_job), do: ""

  defp state_badge("retryable"), do: "badge-warning"
  defp state_badge("discarded"), do: "badge-error"
  defp state_badge(_state), do: "badge-neutral"
end
