defmodule DarkZenith.Repositories.SlugReservation do
  @moduledoc """
  Global authority for live and retired repository slugs (DESIGN.md: Slug
  Reservations). A live row points at its repository; a retired row keeps the
  slug unavailable so a deleted repository's URL cannot be taken over.
  """

  use Ecto.Schema

  @primary_key {:slug, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "slug_reservations" do
    field :repository_id, :binary_id
    field :repository_name, :string
    field :retired_at, :utc_datetime
    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
