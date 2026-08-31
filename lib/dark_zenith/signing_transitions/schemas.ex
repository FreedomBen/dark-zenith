defmodule DarkZenith.SigningTransitions.Transition do
  @moduledoc """
  One durable signing transition (DESIGN.md: Signing Transitions). Progress
  is application data, never inferred from Oban row retention.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "signing_transitions" do
    field :kind, :string
    field :repository_id, :binary_id
    field :target_fingerprint, :string
    field :prepared_gpg_key_private, :binary, redact: true
    field :prepared_gpg_key_public, :string
    field :prepared_primary_fingerprint, :string
    field :prepared_signing_fingerprint, :string
    field :prepared_expires_at, :utc_datetime
    field :repositories_prepared_through, :binary_id
    field :packages_prepared_through, :binary_id
    field :repositories_preparation_complete, :boolean, default: false
    field :packages_preparation_complete, :boolean, default: false
    field :phase_attempts, :integer, default: 0
    field :phase_next_attempt_at, :utc_datetime
    field :last_error_code, :string
    field :status, :string
    field :resume_status, :string
    field :completed_at, :utc_datetime

    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end
end

defmodule DarkZenith.SigningTransitions.TransitionRepository do
  @moduledoc "Durable per-repository snapshot row (DESIGN.md)."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "signing_transition_repositories" do
    field :repository_id, :binary_id
    field :application_status, :string, default: "pending"
    field :applied_at, :utc_datetime

    belongs_to :transition, DarkZenith.SigningTransitions.Transition

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule DarkZenith.SigningTransitions.Item do
  @moduledoc "Durable per-package outcome row (DESIGN.md: Signing Transition Items)."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "signing_transition_items" do
    field :repository_id, :binary_id
    field :package_id, :binary_id
    field :expected_storage_path, :string
    field :expected_storage_version_id, :string
    field :reservation_id, :binary_id
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime
    field :last_error_code, :string
    field :completed_at, :utc_datetime

    belongs_to :transition, DarkZenith.SigningTransitions.Transition

    timestamps(type: :utc_datetime)
  end
end
