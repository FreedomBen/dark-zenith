defmodule DarkZenith.Repo.Migrations.CreateCollaborators do
  use Ecto.Migration

  def change do
    create table(:collaborators, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      # Membership rows where the user is the collaborator are removed when
      # that user is deleted (DESIGN.md: User Lifecycle).
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :notification_status, :string, null: false
      add :notification_generation, :bigint, null: false, default: 1
      add :notification_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collaborators, [:repository_id, :user_id])
    create index(:collaborators, [:user_id])

    # Collaborators are registered users, so there is no suppressed state.
    create constraint(:collaborators, :collaborators_notification_status,
             check: "notification_status IN ('queued', 'sent', 'failed')"
           )

    create constraint(:collaborators, :collaborators_notification_generation_positive,
             check: "notification_generation > 0"
           )

    create constraint(:collaborators, :collaborators_sent_at_matches_status,
             check: "(notification_status = 'sent') = (notification_sent_at IS NOT NULL)"
           )

    create table(:collaborator_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :email, :citext, null: false

      # Pending invitations a user sent are removed when that user is deleted
      # (DESIGN.md: User Lifecycle).
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :expires_at, :utc_datetime
      add :notification_status, :string, null: false
      add :notification_generation, :bigint, null: false, default: 0
      add :notification_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collaborator_invitations, [:repository_id, :email])
    create index(:collaborator_invitations, [:email])
    create index(:collaborator_invitations, [:invited_by_id])
    # The hourly cleanup job scans by expiry.
    create index(:collaborator_invitations, [:expires_at])

    create constraint(:collaborator_invitations, :collaborator_invitations_notification_status,
             check: "notification_status IN ('suppressed', 'queued', 'sent', 'failed')"
           )

    create constraint(
             :collaborator_invitations,
             :collaborator_invitations_notification_generation_non_negative,
             check: "notification_generation >= 0"
           )

    create constraint(:collaborator_invitations, :collaborator_invitations_sent_at_matches_status,
             check: "(notification_status = 'sent') = (notification_sent_at IS NOT NULL)"
           )
  end
end
