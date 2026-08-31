defmodule DarkZenith.Workers.SigningPhase do
  @moduledoc """
  Runs one bounded phase batch for a user-wide signing transition
  (DESIGN.md: Signing Transitions). Durable phase state owns retries; Oban
  uniqueness is only an efficiency measure.
  """

  use Oban.Worker,
    queue: :rpm_processing,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:transition_id], states: [:available, :scheduled]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"transition_id" => transition_id}}) do
    DarkZenith.SigningTransitions.UserWide.run_phase(transition_id)
  end
end
