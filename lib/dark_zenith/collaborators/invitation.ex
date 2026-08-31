defmodule DarkZenith.Collaborators.Invitation do
  @moduledoc """
  Pending collaborator invitation for a normalized email address that does not
  yet belong to a user account (DESIGN.md: Collaborator Invitations).

  Converts to a collaborator row when a matching account is created or an
  existing account confirms an email change to the invited address. Expired
  invitations are never converted; an hourly job deletes them.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "collaborator_invitations" do
    field :email, :string
    field :expires_at, :utc_datetime
    field :notification_status, :string
    field :notification_generation, :integer, default: 0
    field :notification_sent_at, :utc_datetime

    belongs_to :repository, DarkZenith.Repositories.Repository
    belongs_to :invited_by, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Whether the invitation is expired (never true when expiry is disabled)."
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) != :gt
  end
end
