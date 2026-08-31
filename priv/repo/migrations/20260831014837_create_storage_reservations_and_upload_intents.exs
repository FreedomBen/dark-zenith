defmodule DarkZenith.Repo.Migrations.CreateStorageReservationsAndUploadIntents do
  use Ecto.Migration

  def change do
    create table(:storage_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # User/repository deletion transactions record and release reservations
      # explicitly; the cascades are the database-level backstop.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :package_id, :binary_id, null: false
      add :kind, :string, null: false
      add :reserved_bytes, :bigint, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:storage_reservations, [:user_id])
    create index(:storage_reservations, [:expires_at])

    create constraint(:storage_reservations, :storage_reservations_kind,
             check: "kind IN ('upload', 'resign')"
           )

    create constraint(:storage_reservations, :storage_reservations_bytes_positive,
             check: "reserved_bytes > 0"
           )

    create table(:upload_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :package_id, :binary_id, null: false

      add :reservation_id,
          references(:storage_reservations, type: :binary_id, on_delete: :nilify_all)

      add :mode, :string, null: false
      add :status, :string, null: false, default: "awaiting_upload"
      add :original_filename, :string, null: false
      add :declared_size, :bigint, null: false
      add :upload_generation, :integer, null: false, default: 1
      add :staging_path, :text, null: false
      add :upload_url_expires_at, :utc_datetime
      add :staging_version_id, :text
      add :preview_metadata, :jsonb
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime
      add :last_error_code, :string
      add :expires_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:upload_intents, [:reservation_id], where: "reservation_id IS NOT NULL")

    create unique_index(:upload_intents, [:staging_path])
    create unique_index(:upload_intents, [:package_id])
    create index(:upload_intents, [:repository_id])
    create index(:upload_intents, [:user_id])
    create index(:upload_intents, [:status])

    create constraint(:upload_intents, :upload_intents_mode,
             check: "mode IN ('api', 'web_preview')"
           )

    create constraint(:upload_intents, :upload_intents_declared_size_positive,
             check: "declared_size > 0"
           )

    create constraint(:upload_intents, :upload_intents_generation_positive,
             check: "upload_generation >= 1"
           )

    create constraint(:upload_intents, :upload_intents_api_never_preview,
             check: "NOT (mode = 'api' AND status = 'preview_ready')"
           )

    # The state machine (DESIGN.md: Upload Intents database checks).
    create constraint(:upload_intents, :upload_intents_state,
             check: """
             CASE status
               WHEN 'awaiting_upload' THEN
                 reservation_id IS NOT NULL AND upload_url_expires_at IS NOT NULL AND
                 expires_at IS NOT NULL AND staging_version_id IS NULL AND
                 preview_metadata IS NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND next_attempt_at IS NULL AND completed_at IS NULL
               WHEN 'queued' THEN
                 reservation_id IS NOT NULL AND staging_version_id IS NOT NULL AND
                 next_attempt_at IS NOT NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND completed_at IS NULL AND
                 upload_url_expires_at IS NULL AND expires_at IS NULL
               WHEN 'processing' THEN
                 reservation_id IS NOT NULL AND staging_version_id IS NOT NULL AND
                 lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND
                 next_attempt_at IS NULL AND completed_at IS NULL AND
                 upload_url_expires_at IS NULL AND expires_at IS NULL
               WHEN 'preview_ready' THEN
                 reservation_id IS NOT NULL AND staging_version_id IS NOT NULL AND
                 mode = 'web_preview' AND preview_metadata IS NOT NULL AND
                 expires_at IS NOT NULL AND next_attempt_at IS NULL AND
                 lease_token IS NULL AND lease_expires_at IS NULL AND
                 completed_at IS NULL AND upload_url_expires_at IS NULL
               WHEN 'succeeded' THEN
                 reservation_id IS NULL AND completed_at IS NOT NULL AND
                 next_attempt_at IS NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND expires_at IS NULL AND
                 upload_url_expires_at IS NULL
               WHEN 'failed' THEN
                 reservation_id IS NULL AND completed_at IS NOT NULL AND
                 last_error_code IS NOT NULL AND next_attempt_at IS NULL AND
                 lease_token IS NULL AND lease_expires_at IS NULL AND
                 expires_at IS NULL AND upload_url_expires_at IS NULL
               WHEN 'expired' THEN
                 reservation_id IS NULL AND completed_at IS NOT NULL AND
                 next_attempt_at IS NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND expires_at IS NULL AND
                 upload_url_expires_at IS NULL
               WHEN 'canceled' THEN
                 reservation_id IS NULL AND completed_at IS NOT NULL AND
                 next_attempt_at IS NULL AND lease_token IS NULL AND
                 lease_expires_at IS NULL AND expires_at IS NULL AND
                 upload_url_expires_at IS NULL
               ELSE false
             END
             """
           )
  end
end
