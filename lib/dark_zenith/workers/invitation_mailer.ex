defmodule DarkZenith.Workers.InvitationMailer do
  @moduledoc """
  Delivers the registration-link notification for one invitation delivery
  generation (DESIGN.md: Collaborator Invitations).

  Jobs are unique on `(invitation_id, notification_generation)`. The worker
  reloads the row and no-ops unless both the generation and `queued` status
  still match; deleting the invitation (cancellation or conversion) fences its
  stale mail job. Provider success atomically records `sent`; the twentieth
  failure records `failed` before the job is discarded.
  """

  use Oban.Worker,
    queue: :mailers,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:invitation_id, :notification_generation]]

  import Ecto.Query

  alias DarkZenith.Collaborators.Invitation
  alias DarkZenith.Repo
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"invitation_id" => id, "notification_generation" => generation} = args

    invitation =
      Repo.one(from i in Invitation, where: i.id == ^id, preload: [:repository])

    case invitation do
      %Invitation{notification_generation: ^generation, notification_status: "queued"} = row ->
        deliver(row, generation, job)

      # Row deleted (canceled/converted), generation superseded, or resolved.
      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp deliver(invitation, generation, job) do
    case notifier().deliver_invitation(invitation.email, invitation.repository) do
      {:ok, _} ->
        mark(invitation, generation, "sent", DateTime.utc_now(:second))
        :ok

      {:error, reason} ->
        if job.attempt >= job.max_attempts do
          mark(invitation, generation, "failed", nil)
        end

        {:error, reason}
    end
  end

  defp mark(invitation, generation, status, sent_at) do
    Repo.update_all(
      from(i in Invitation,
        where:
          i.id == ^invitation.id and i.notification_generation == ^generation and
            i.notification_status == "queued"
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
