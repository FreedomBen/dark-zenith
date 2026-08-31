defmodule DarkZenith.Repo.Migrations.AddGpgKeyTransitionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Unresolved user-wide key transition; cleared only by its terminal
      # transaction (DESIGN.md: Users).
      add :gpg_key_transition_id,
          references(:signing_transitions, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
