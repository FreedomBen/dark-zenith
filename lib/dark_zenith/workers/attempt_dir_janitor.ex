defmodule DarkZenith.Workers.AttemptDirJanitor do
  @moduledoc """
  Hourly cron: removes stale attempt directories whose token no longer
  holds a temporary-space lease (DESIGN.md: Signing Transition Items).
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _removed} =
      DarkZenith.TempSpace.hourly_janitor(
        Application.get_env(:dark_zenith, :temp_space_server, DarkZenith.TempSpace)
      )

    :ok
  end
end
