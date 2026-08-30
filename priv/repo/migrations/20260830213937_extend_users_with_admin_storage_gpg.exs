defmodule DarkZenith.Repo.Migrations.ExtendUsersWithAdminStorageGpg do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_admin, :boolean, null: false, default: false
      add :storage_bytes, :bigint, null: false, default: 0
      add :gpg_key_private, :binary
      add :gpg_key_public, :text
      add :gpg_key_fingerprint, :string
      add :gpg_signing_fingerprint, :string
      add :gpg_key_expires_at, :utc_datetime
      add :gpg_key_expiry_notified_days, :jsonb, null: false, default: "[]"
      add :previous_gpg_key_public, :text
    end

    create constraint(:users, :users_storage_bytes_non_negative, check: "storage_bytes >= 0")

    # The encrypted private key, public key, primary fingerprint, and exact
    # signing fingerprint are always written or cleared together; expiry may be
    # null for a non-expiring key (DESIGN.md: Users).
    create constraint(:users, :users_gpg_key_fields_together,
             check: """
             (gpg_key_private IS NULL AND gpg_key_public IS NULL AND
              gpg_key_fingerprint IS NULL AND gpg_signing_fingerprint IS NULL AND
              gpg_key_expires_at IS NULL)
             OR
             (gpg_key_private IS NOT NULL AND gpg_key_public IS NOT NULL AND
              gpg_key_fingerprint IS NOT NULL AND gpg_signing_fingerprint IS NOT NULL)
             """
           )
  end
end
