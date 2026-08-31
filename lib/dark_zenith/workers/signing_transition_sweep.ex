defmodule DarkZenith.Workers.SigningTransitionSweep do
  @moduledoc """
  60-second signing-transition sweep (DESIGN.md: RPM signing): requeues
  expired item execution leases and completes enable transitions from
  durable item state plus the metadata cache revision.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.SigningTransitions.sweep()
  end
end
