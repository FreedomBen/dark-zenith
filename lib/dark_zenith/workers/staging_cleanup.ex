defmodule DarkZenith.Workers.StagingCleanup do
  @moduledoc """
  Key-scoped version-aware staging cleanup (DESIGN.md: Upload Intents).

  Lists every version at the exact random staging key and permanently
  deletes each one — the accepted version and any siblings a replayed
  presigned URL created. Never issues an unversioned delete. Staging keys
  are fixed-length random names, so a prefix listing of the full key
  matches only that key. Already-absent versions are success; other
  object-storage errors retry under Background Retry Policy.
  """

  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:staging_path], states: [:available, :scheduled]]

  alias DarkZenith.B2
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"staging_path" => staging_path}}) do
    config = B2.config!()

    with {:ok, entries} <- B2.list_all_object_versions(config, staging_path) do
      results =
        for entry <- entries, entry.key == staging_path do
          B2.delete_version(config, entry.key, entry.version_id)
        end

      if Enum.all?(results, &(&1 == :ok)) do
        :ok
      else
        {:error, :storage_unavailable}
      end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)
end
