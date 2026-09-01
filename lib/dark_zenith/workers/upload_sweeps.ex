defmodule DarkZenith.Workers.UploadLeaseSweep do
  @moduledoc """
  60-second sweep: requeues processing intents whose lease expired and
  renews queued/processing storage reservations two hours ahead
  (DESIGN.md: Upload Intents).
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.Uploads.requeue_expired_leases()
  end
end

defmodule DarkZenith.Workers.UploadWaitingCleanup do
  @moduledoc """
  15-minute sweep expiring overdue `awaiting_upload`/`preview_ready` rows.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.Uploads.expire_overdue()
  end
end

defmodule DarkZenith.Workers.UploadTerminalCleanup do
  @moduledoc """
  Hourly deletion of terminal intent rows older than 24 hours, plus expired
  unlinked storage reservations. A second query is the upload-record safety
  net: any `in_flight` record whose intent row is gone is finalized as
  `canceled` (DESIGN.md: Package Upload Records).
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    DarkZenith.Uploads.delete_old_terminal()
    DarkZenith.Uploads.reconcile_orphaned_records()
    DarkZenith.Storage.cleanup_expired()
  end
end
