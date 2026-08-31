defmodule DarkZenith.Workers.InvitationCleanup do
  @moduledoc """
  Hourly deletion of expired collaborator invitations (DESIGN.md:
  Collaborator Invitations). Expired invitations are never converted; this
  job frees the quota slots they occupy.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.Collaborators.delete_expired_invitations()
    :ok
  end
end
