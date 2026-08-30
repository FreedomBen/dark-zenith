defmodule DarkZenith.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # User deletion is rejected while the user still owns repositories
      # (DESIGN.md: User Lifecycle); RESTRICT backs that at the database level.
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :gpg_key_fingerprint, :string
      add :sign_rpms, :boolean, null: false, default: false
      add :rpm_signing_state, :string, null: false, default: "disabled"
      # FK to signing_transitions arrives with that table (Phase 11).
      add :signing_transition_id, :binary_id
      add :is_public, :boolean, null: false, default: false
      add :metadata_revision, :bigint, null: false, default: 0
      add :package_count, :bigint, null: false, default: 0
      add :primary_open_bytes, :bigint, null: false
      add :filelists_open_bytes, :bigint, null: false
      add :other_open_bytes, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repositories, [:slug])
    create index(:repositories, [:user_id])

    create constraint(:repositories, :repositories_rpm_signing_state,
             check: "rpm_signing_state IN ('disabled', 'signing', 'enabled')"
           )

    create constraint(:repositories, :repositories_sign_rpms_requires_fingerprint,
             check: "NOT sign_rpms OR gpg_key_fingerprint IS NOT NULL"
           )

    create constraint(:repositories, :repositories_counters_non_negative,
             check: """
             metadata_revision >= 0 AND package_count >= 0 AND
             primary_open_bytes >= 0 AND filelists_open_bytes >= 0 AND
             other_open_bytes >= 0
             """
           )

    create table(:slug_reservations, primary_key: false) do
      add :slug, :string, primary_key: true
      add :repository_id, :binary_id
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :repository_name, :string, null: false
      add :retired_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The repository FK is DEFERRABLE INITIALLY DEFERRED so the reservation can
    # be claimed before its repository row is inserted (DESIGN.md: Slug
    # Reservations).
    execute(
      """
      ALTER TABLE slug_reservations
      ADD CONSTRAINT slug_reservations_repository_id_fkey
      FOREIGN KEY (repository_id) REFERENCES repositories(id)
      DEFERRABLE INITIALLY DEFERRED
      """,
      "ALTER TABLE slug_reservations DROP CONSTRAINT slug_reservations_repository_id_fkey"
    )

    create unique_index(:slug_reservations, [:repository_id], where: "repository_id IS NOT NULL")

    # Exactly one of the two states: live (repository + owner, not retired) or
    # retired (no repository, retired_at set, owner may be null after account
    # deletion).
    create constraint(:slug_reservations, :slug_reservations_state,
             check: """
             (repository_id IS NOT NULL AND user_id IS NOT NULL AND retired_at IS NULL)
             OR
             (repository_id IS NULL AND retired_at IS NOT NULL)
             """
           )

    create table(:repository_metadata_caches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :primary_xml_gz, :binary, null: false
      add :filelists_xml_gz, :binary, null: false
      add :other_xml_gz, :binary, null: false
      add :repomd_xml, :text, null: false
      add :repomd_xml_asc, :text
      add :source_revision, :bigint, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repository_metadata_caches, [:repository_id])
  end
end
