defmodule DarkZenith.Repo.Migrations.AddLastErrorDetailToUploadIntents do
  use Ecto.Migration

  # Optional sanitized reason refining last_error_code (DESIGN.md: Upload
  # Failure Reasons). Nullable in every state, including `failed`, so the
  # existing state-machine check needs no change.
  def change do
    alter table(:upload_intents) do
      add :last_error_detail, :string
    end
  end
end
