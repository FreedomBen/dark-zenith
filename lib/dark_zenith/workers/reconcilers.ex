defmodule DarkZenith.Workers.StagingReconciler do
  @moduledoc """
  Hourly staging reconciler (DESIGN.md: Package Upload & Processing).

  Scans `staging/uploads/` and preserves every version at the current key of
  an unexpired `awaiting_upload` intent, the accepted exact version of an
  active `queued`/`processing`/`preview_ready` intent, and versions younger
  than two hours that may belong to an in-flight transfer; it deletes
  everything else, always by exact version.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 20

  import Ecto.Query

  alias DarkZenith.B2
  alias DarkZenith.Repo
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.RetryPolicy

  @grace_seconds 2 * 3600

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    config = B2.config!()
    now = DateTime.utc_now(:second)

    with {:ok, entries} <- B2.list_all_object_versions(config, "staging/uploads/") do
      awaiting_keys =
        MapSet.new(
          Repo.all(
            from i in Intent,
              where: i.status == "awaiting_upload" and i.expires_at > ^now,
              select: i.staging_path
          )
        )

      accepted =
        MapSet.new(
          Repo.all(
            from i in Intent,
              where: i.status in ["queued", "processing", "preview_ready"],
              select: {i.staging_path, i.staging_version_id}
          )
        )

      results =
        for entry <- entries, not keep?(entry, awaiting_keys, accepted, now) do
          B2.delete_version(config, entry.key, entry.version_id)
        end

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :storage_unavailable}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp keep?(entry, awaiting_keys, accepted, now) do
    MapSet.member?(awaiting_keys, entry.key) or
      MapSet.member?(accepted, {entry.key, entry.version_id}) or
      young?(entry.last_modified, now)
  end

  # A version without a parseable timestamp is treated as young rather than
  # risking deletion of an in-flight transfer.
  defp young?(nil, _now), do: true
  defp young?(last_modified, now), do: DateTime.diff(now, last_modified) < @grace_seconds
end

defmodule DarkZenith.Workers.FinalReconciler do
  @moduledoc """
  Daily final-object reconciler (DESIGN.md: Package Upload & Processing).

  Paginates every version under `repos/`, compares `(key, version_id)`
  pairs with package rows, and permanently deletes unreferenced versions
  and delete markers older than 24 hours.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 20

  import Ecto.Query

  alias DarkZenith.B2
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Workers.RetryPolicy

  @grace_seconds 24 * 3600

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    config = B2.config!()
    now = DateTime.utc_now(:second)

    with {:ok, entries} <- B2.list_all_object_versions(config, "repos/") do
      referenced =
        MapSet.new(Repo.all(from p in Package, select: {p.storage_path, p.storage_version_id}))

      results =
        for entry <- entries,
            not MapSet.member?(referenced, {entry.key, entry.version_id}),
            old?(entry.last_modified, now) do
          B2.delete_version(config, entry.key, entry.version_id)
        end

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :storage_unavailable}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp old?(nil, _now), do: false
  defp old?(last_modified, now), do: DateTime.diff(now, last_modified) >= @grace_seconds
end
