defmodule DarkZenith.Repo.Migrations.CreatePackageUploadRecords do
  use Ecto.Migration

  @outcomes ~w(in_flight succeeded failed expired canceled)

  def up do
    create table(:package_upload_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # UUID snapshots rather than foreign keys: a record outlives its
      # repository and its intent (DESIGN.md: Package Upload Records).
      add :repository_id, :binary_id, null: false
      add :repository_slug, :string, null: false

      # Attribution survives account deletion through the email snapshot.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :user_email, :string, null: false

      add :intent_id, :binary_id, null: false
      add :package_id, :binary_id, null: false
      add :mode, :string, null: false
      add :original_filename, :string, null: false
      add :declared_size, :bigint, null: false
      add :final_size, :bigint
      add :outcome, :string, null: false, default: "in_flight"
      add :error_code, :string
      add :error_detail, :string
      add :nevra, :string
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:package_upload_records, [:intent_id])
    create index(:package_upload_records, [:repository_id, "started_at DESC", :id])
    create index(:package_upload_records, [:user_id])
    create index(:package_upload_records, [:package_id])

    # The repository's in-flight count, read on every Upload History render.
    create index(:package_upload_records, [:repository_id],
             where: "outcome = 'in_flight'",
             name: :package_upload_records_in_flight_index
           )

    # The admin upload-record view and its filters.
    create index(:package_upload_records, ["started_at DESC", :id])
    create index(:package_upload_records, [:repository_slug, "started_at DESC", :id])
    create index(:package_upload_records, [:user_email, "started_at DESC", :id])

    outcomes_list = Enum.map_join(@outcomes, ", ", &"'#{&1}'")

    create constraint(:package_upload_records, :package_upload_records_outcome,
             check: "outcome IN (#{outcomes_list})"
           )

    create constraint(:package_upload_records, :package_upload_records_mode,
             check: "mode IN ('api', 'web_preview')"
           )

    create constraint(:package_upload_records, :package_upload_records_declared_size_positive,
             check: "declared_size > 0"
           )

    # Outcome-scoped fields: final_size/nevra only on success (both nullable
    # there, for a backfilled record whose package row was already gone),
    # error fields only on failure, finished_at exactly when terminal.
    create constraint(:package_upload_records, :package_upload_records_state,
             check: """
             CASE outcome
               WHEN 'in_flight' THEN
                 finished_at IS NULL AND final_size IS NULL AND nevra IS NULL AND
                 error_code IS NULL AND error_detail IS NULL
               WHEN 'succeeded' THEN
                 finished_at IS NOT NULL AND error_code IS NULL AND error_detail IS NULL
               WHEN 'failed' THEN
                 finished_at IS NOT NULL AND error_code IS NOT NULL AND
                 final_size IS NULL AND nevra IS NULL
               ELSE
                 finished_at IS NOT NULL AND final_size IS NULL AND nevra IS NULL AND
                 error_code IS NULL AND error_detail IS NULL
             END
             """
           )

    execute(backfill_sql())
  end

  def down do
    drop table(:package_upload_records)
  end

  @doc """
  One record per upload intent row that has none (DESIGN.md: Package Upload
  Records — backfill): `outcome` follows the intent status, `started_at` is
  the intent's `inserted_at`, `finished_at` its `completed_at`, a failed
  intent's error code/detail carry over, and a succeeded intent takes
  `nevra`/`final_size` from its package row when that row still exists.
  `inserted_at` is the migration time.
  """
  def backfill_sql do
    """
    INSERT INTO package_upload_records
      (id, repository_id, repository_slug, user_id, user_email, intent_id, package_id,
       mode, original_filename, declared_size, final_size, outcome, error_code,
       error_detail, nevra, started_at, finished_at, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      i.repository_id,
      r.slug,
      i.user_id,
      u.email,
      i.id,
      i.package_id,
      i.mode,
      i.original_filename,
      i.declared_size,
      CASE WHEN i.status = 'succeeded' THEN p.size_package END,
      CASE WHEN i.status IN ('succeeded', 'failed', 'expired', 'canceled')
           THEN i.status ELSE 'in_flight' END,
      CASE WHEN i.status = 'failed' THEN i.last_error_code END,
      CASE WHEN i.status = 'failed' THEN i.last_error_detail END,
      CASE WHEN i.status = 'succeeded' AND p.id IS NOT NULL THEN
        p.name || '-' || p.epoch || ':' || p.version || '-' || p.release || '.' || p.arch
      END,
      i.inserted_at,
      i.completed_at,
      now(),
      now()
    FROM upload_intents i
    JOIN repositories r ON r.id = i.repository_id
    JOIN users u ON u.id = i.user_id
    LEFT JOIN packages p ON p.id = i.package_id
    WHERE NOT EXISTS (
      SELECT 1 FROM package_upload_records x WHERE x.intent_id = i.id
    )
    """
  end
end
