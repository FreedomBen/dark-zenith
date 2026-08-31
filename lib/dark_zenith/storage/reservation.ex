defmodule DarkZenith.Storage.Reservation do
  @moduledoc """
  Short-lived per-owner storage-quota reservation (DESIGN.md: Storage
  Reservations). `reserved_bytes` holds the declared source size until
  processing reserves the exact final size, or the positive re-sign delta.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "storage_reservations" do
    field :package_id, :binary_id
    field :kind, :string
    field :reserved_bytes, :integer
    field :expires_at, :utc_datetime

    belongs_to :user, DarkZenith.Accounts.User
    belongs_to :repository, DarkZenith.Repositories.Repository

    timestamps(type: :utc_datetime)
  end
end
