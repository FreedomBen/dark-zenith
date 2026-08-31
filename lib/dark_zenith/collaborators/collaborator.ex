defmodule DarkZenith.Collaborators.Collaborator do
  @moduledoc """
  Read access granted to a registered user on a private repository
  (DESIGN.md: Repository Collaborators).

  `notification_*` fields track direct repository-link mail delivery for the
  current generation; collaborators are registered users, so there is no
  `suppressed` state.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "collaborators" do
    field :notification_status, :string
    field :notification_generation, :integer, default: 1
    field :notification_sent_at, :utc_datetime

    belongs_to :repository, DarkZenith.Repositories.Repository
    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
