defmodule DarkZenith.Repo.Migrations.CreateSigningTransitions do
  use Ecto.Migration

  def change do
    create table(:signing_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false

      # Retained for audit when the owner is deleted.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # Repository UUID snapshot (no FK) for enable_rpm_signing.
      add :repository_id, :binary_id
      add :target_fingerprint, :string
      add :prepared_gpg_key_private, :binary
      add :prepared_gpg_key_public, :text
      add :prepared_primary_fingerprint, :string
      add :prepared_signing_fingerprint, :string
      add :prepared_expires_at, :utc_datetime
      add :repositories_prepared_through, :binary_id
      add :packages_prepared_through, :binary_id
      add :repositories_preparation_complete, :boolean, null: false, default: false
      add :packages_preparation_complete, :boolean, null: false, default: false
      add :phase_attempts, :integer, null: false, default: 0
      add :phase_next_attempt_at, :utc_datetime
      add :last_error_code, :string
      add :status, :string, null: false
      add :resume_status, :string
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:signing_transitions, [:user_id])
    create index(:signing_transitions, [:repository_id])

    create constraint(:signing_transitions, :signing_transitions_kind,
             check:
               "kind IN ('enable_rpm_signing', 'replace_gpg_key', 'clear_metadata_signing', 'delete_signed_packages')"
           )

    create constraint(:signing_transitions, :signing_transitions_status,
             check:
               "status IN ('preparing', 'activating', 'active', 'finalizing', 'failed', 'completed', 'canceled')"
           )

    # failed requires resume_status + last_error_code; terminal states
    # require completed_at and clear resume/scheduling state.
    create constraint(:signing_transitions, :signing_transitions_failed_fields,
             check:
               "status <> 'failed' OR (resume_status IS NOT NULL AND last_error_code IS NOT NULL)"
           )

    create constraint(:signing_transitions, :signing_transitions_terminal_fields,
             check: """
             CASE
               WHEN status IN ('completed', 'canceled') THEN
                 completed_at IS NOT NULL AND resume_status IS NULL AND
                 phase_next_attempt_at IS NULL
               ELSE completed_at IS NULL
             END
             """
           )

    create constraint(:signing_transitions, :signing_transitions_resume_status,
             check:
               "resume_status IS NULL OR resume_status IN ('preparing', 'activating', 'active', 'finalizing')"
           )

    # At most one unresolved user-wide transition per user.
    create unique_index(:signing_transitions, [:user_id],
             where: """
             kind IN ('replace_gpg_key', 'clear_metadata_signing', 'delete_signed_packages')
             AND status IN ('preparing', 'activating', 'active', 'finalizing', 'failed')
             """,
             name: :signing_transitions_one_unresolved_user_wide
           )

    create table(:signing_transition_repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transition_id,
          references(:signing_transitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :repository_id, :binary_id, null: false
      add :application_status, :string, null: false, default: "pending"
      add :applied_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:signing_transition_repositories, [:transition_id, :repository_id])

    create constraint(
             :signing_transition_repositories,
             :signing_transition_repositories_status,
             check: "application_status IN ('pending', 'applied', 'satisfied_deleted')"
           )

    create constraint(
             :signing_transition_repositories,
             :signing_transition_repositories_applied_at,
             check: "(application_status = 'pending') = (applied_at IS NULL)"
           )

    create table(:signing_transition_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transition_id,
          references(:signing_transitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :repository_id, :binary_id, null: false
      add :package_id, :binary_id, null: false
      add :expected_storage_path, :text, null: false
      add :expected_storage_version_id, :text, null: false

      add :reservation_id,
          references(:storage_reservations, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime
      add :last_error_code, :string
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:signing_transition_items, [:transition_id, :package_id])

    create unique_index(:signing_transition_items, [:reservation_id],
             where: "reservation_id IS NOT NULL"
           )

    create index(:signing_transition_items, [:package_id])
    create index(:signing_transition_items, [:status])

    create constraint(:signing_transition_items, :signing_transition_items_status,
             check: "status IN ('pending', 'executing', 'succeeded', 'failed', 'canceled')"
           )

    create constraint(:signing_transition_items, :signing_transition_items_state,
             check: """
             CASE status
               WHEN 'pending' THEN
                 next_attempt_at IS NOT NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND completed_at IS NULL
               WHEN 'executing' THEN
                 lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND
                 next_attempt_at IS NULL AND completed_at IS NULL
               ELSE
                 completed_at IS NOT NULL AND reservation_id IS NULL AND
                 next_attempt_at IS NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND
                 (status <> 'failed' OR last_error_code IS NOT NULL)
             END
             """
           )
  end
end
