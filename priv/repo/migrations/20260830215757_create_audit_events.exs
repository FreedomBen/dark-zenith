defmodule DarkZenith.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  @target_types ~w(repository package upload_intent user api_key gpg_key collaborator invitation signing_transition signing_transition_item slug)

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_email, :string
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :binary_id
      add :ip, :string
      add :metadata, :jsonb, null: false, default: "{}"

      # Microsecond resolution keeps ordering meaningful for events recorded
      # within the same second.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    types_list = Enum.map_join(@target_types, ", ", &"'#{&1}'")

    create constraint(:audit_events, :audit_events_target_type,
             check: "target_type IS NULL OR target_type IN (#{types_list})"
           )

    # Slug targets are string-keyed; the slug itself lives in metadata.
    create constraint(:audit_events, :audit_events_slug_target_id_null,
             check: "target_type IS DISTINCT FROM 'slug' OR target_id IS NULL"
           )

    create index(:audit_events, [:actor_id])
    create index(:audit_events, [:action])
    create index(:audit_events, [:inserted_at])
    create index(:audit_events, [:target_type, :target_id])
  end
end
