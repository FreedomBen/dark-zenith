defmodule DarkZenith.Uploads.Intent do
  @moduledoc """
  Durable authority for one direct-to-B2 upload (DESIGN.md: Upload Intents).
  Database check constraints enforce the state machine; this schema carries
  the fields.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "upload_intents" do
    field :package_id, :binary_id
    field :mode, :string
    field :status, :string, default: "awaiting_upload"
    field :original_filename, :string
    field :declared_size, :integer
    field :upload_generation, :integer, default: 1
    field :staging_path, :string
    field :upload_url_expires_at, :utc_datetime
    field :staging_version_id, :string
    field :preview_metadata, :map
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime
    field :last_error_code, :string
    field :last_error_detail, :string
    field :expires_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :repository, DarkZenith.Repositories.Repository
    belongs_to :user, DarkZenith.Accounts.User
    belongs_to :reservation, DarkZenith.Storage.Reservation

    timestamps(type: :utc_datetime)
  end
end
