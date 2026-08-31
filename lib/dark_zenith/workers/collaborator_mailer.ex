defmodule DarkZenith.Workers.CollaboratorMailer do
  @moduledoc """
  Delivers the direct repository-link notification for one collaborator
  delivery generation (DESIGN.md: Collaborator Invitations — direct
  collaborator mail uses the same state machine).

  Jobs are unique on `(collaborator_id, notification_generation)`. The worker
  reloads the row and no-ops unless both the generation and `queued` status
  still match, so a delayed worker from an older generation can never
  overwrite newer state.
  """

  use Oban.Worker,
    queue: :mailers,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:collaborator_id, :notification_generation]]

  import Ecto.Query

  alias DarkZenith.Collaborators.Collaborator
  alias DarkZenith.Repo
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"collaborator_id" => id, "notification_generation" => generation} = args

    collaborator =
      Repo.one(
        from c in Collaborator,
          where: c.id == ^id,
          preload: [:user, :repository]
      )

    case collaborator do
      %Collaborator{notification_generation: ^generation, notification_status: "queued"} = row ->
        deliver(row, generation, job)

      # Row deleted, generation superseded, or already sent/failed.
      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp deliver(collaborator, generation, job) do
    case notifier().deliver_collaborator_added(collaborator.user.email, collaborator.repository) do
      {:ok, _} ->
        mark(collaborator, generation, "sent", DateTime.utc_now(:second))
        :ok

      {:error, reason} ->
        if job.attempt >= job.max_attempts do
          mark(collaborator, generation, "failed", nil)
        end

        {:error, reason}
    end
  end

  # Guarded on generation and queued status so a raced newer generation is
  # never overwritten.
  defp mark(collaborator, generation, status, sent_at) do
    Repo.update_all(
      from(c in Collaborator,
        where:
          c.id == ^collaborator.id and c.notification_generation == ^generation and
            c.notification_status == "queued"
      ),
      set: [
        notification_status: status,
        notification_sent_at: sent_at,
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp notifier do
    Application.get_env(:dark_zenith, :collaborator_notifier, DarkZenith.Collaborators.Notifier)
  end
end
