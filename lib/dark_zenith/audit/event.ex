defmodule DarkZenith.Audit.Event do
  @moduledoc """
  One append-only audit event row. See `DarkZenith.Audit`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :actor_id, :binary_id
    field :actor_email, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :ip, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
