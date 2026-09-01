defmodule DarkZenith.Uploads.Record do
  @moduledoc """
  One durable package upload record (DESIGN.md: Package Upload Records):
  the append-mostly counterpart of an upload intent that outlives the
  intent, its repository, and the initiator's account. `repository_id`,
  `repository_slug`, `intent_id`, and `user_email` are snapshots, not
  foreign keys; only `user_id` is a (nilify-on-delete) reference.

  `live_status` is virtual: the backing intent's current status, filled by
  the listing queries only while the record is `in_flight` and that intent
  row still exists.
  """

  use Ecto.Schema

  @outcomes ~w(in_flight succeeded failed expired canceled)
  @terminal_outcomes ~w(succeeded failed expired canceled)
  @live_statuses ~w(awaiting_upload queued processing preview_ready)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "package_upload_records" do
    field :repository_id, :binary_id
    field :repository_slug, :string
    field :user_id, :binary_id
    field :user_email, :string
    field :intent_id, :binary_id
    field :package_id, :binary_id
    field :mode, :string
    field :original_filename, :string
    field :declared_size, :integer
    field :final_size, :integer
    field :outcome, :string, default: "in_flight"
    field :error_code, :string
    field :error_detail, :string
    field :nevra, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :live_status, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc "Every outcome, in the order the UI filters present them."
  def outcomes, do: @outcomes

  @doc "The outcomes a record can be finalized to."
  def terminal_outcomes, do: @terminal_outcomes

  @doc "The intent statuses a `live_status` can carry."
  def live_statuses, do: @live_statuses
end
