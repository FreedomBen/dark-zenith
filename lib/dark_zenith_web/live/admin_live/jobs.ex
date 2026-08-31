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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-6">
        <.header>
          Background jobs
          <:subtitle><DarkZenithWeb.AdminComponents.admin_nav active="jobs" /></:subtitle>
        </.header>

        <p class="text-sm text-base-content/70">
          Retryable, discarded, and cancelled jobs. Retrying a row re-runs the worker; the
          durable upload/signing state machines still fence stale attempts.
        </p>

        <div :if={@jobs == []} class="text-sm text-base-content/60">
          No failed or exhausted jobs.
        </div>

        <div :if={@jobs != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Worker</th>
                <th>Queue</th>
                <th>State</th>
                <th>Attempt</th>
                <th>Last error</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @jobs} id={"job-#{job.id}"}>
                <td class="font-mono text-xs">{job.worker}</td>
                <td>{job.queue}</td>
                <td>{job.state}</td>
                <td>{job.attempt}/{job.max_attempts}</td>
                <td class="max-w-md truncate text-xs">{last_error(job)}</td>
                <td class="text-right space-x-1">
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
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
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
end
