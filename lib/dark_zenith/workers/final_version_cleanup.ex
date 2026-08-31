defmodule DarkZenith.Workers.FinalVersionCleanup do
  @moduledoc """
  Permanently deletes one exact final B2 object version after package or
  repository deletion (DESIGN.md: Package Upload & Processing). An
  already-absent version is success; other object-storage errors retry
  under Background Retry Policy.
  """

  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:storage_path, :version_id], states: [:available, :scheduled]]

  alias DarkZenith.B2
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"storage_path" => key, "version_id" => version_id}}) do
    B2.delete_version(B2.config!(), key, version_id)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)
end
