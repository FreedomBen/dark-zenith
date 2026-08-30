defmodule DarkZenith.Repo.Migrations.CreateSessionTokens do
  use Ecto.Migration

  def change do
    create table(:session_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:session_tokens, [:token_hash])
    create index(:session_tokens, [:user_id])
  end
end
