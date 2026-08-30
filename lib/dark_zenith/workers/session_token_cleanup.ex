defmodule DarkZenith.Workers.SessionTokenCleanup do
  @moduledoc """
  Hourly cleanup of expired API session tokens (DESIGN.md: Session Tokens).
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.Accounts.delete_expired_session_tokens()
    :ok
  end
end
