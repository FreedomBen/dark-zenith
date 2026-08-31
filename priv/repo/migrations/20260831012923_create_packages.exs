defmodule DarkZenith.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  def change do
    create table(:packages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :rpm_format, :smallint, null: false
      add :name, :string, null: false
      add :epoch, :bigint, null: false, default: 0
      add :version, :string, null: false
      add :release, :string, null: false
      add :arch, :string, null: false
      add :summary, :string, null: false
      add :description, :text, null: false
      add :url, :string
      add :license, :string, null: false
      add :size_installed, :bigint, null: false
      add :size_package, :bigint, null: false
      add :size_archive, :bigint
      add :sha256, :string, null: false
      add :build_time, :utc_datetime
      add :rpm_sourcerpm, :string, size: 800
      add :rpm_sourcenevr, :string, size: 800
      add :rpm_group, :string
      add :rpm_vendor, :string
      add :rpm_buildhost, :string
      add :header_start, :bigint, null: false
      add :header_end, :bigint, null: false
      add :storage_path, :text, null: false
      add :storage_version_id, :text, null: false
      add :requires, :jsonb, null: false, default: "[]"
      add :provides, :jsonb, null: false, default: "[]"
      add :conflicts, :jsonb, null: false, default: "[]"
      add :obsoletes, :jsonb, null: false, default: "[]"
      add :recommends, :jsonb, null: false, default: "[]"
      add :suggests, :jsonb, null: false, default: "[]"
      add :supplements, :jsonb, null: false, default: "[]"
      add :enhances, :jsonb, null: false, default: "[]"
      add :files, :jsonb, null: false, default: "[]"
      add :changelogs, :jsonb, null: false, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:packages, [:repository_id, :name, :epoch, :version, :release, :arch])
    create index(:packages, [:repository_id])

    create constraint(:packages, :packages_rpm_format, check: "rpm_format IN (4, 6)")

    create constraint(:packages, :packages_epoch_range,
             check: "epoch >= 0 AND epoch <= 4294967295"
           )

    create constraint(:packages, :packages_sizes,
             check: """
             size_installed >= 0 AND size_package > 0 AND
             (size_archive IS NULL OR size_archive >= 0)
             """
           )

    # v6 rows require a non-null archive size (DESIGN.md: Packages).
    create constraint(:packages, :packages_v6_archive_size,
             check: "rpm_format <> 6 OR size_archive IS NOT NULL"
           )

    create constraint(:packages, :packages_header_range,
             check:
               "header_start >= 0 AND header_start < header_end AND header_end <= size_package"
           )

    create constraint(:packages, :packages_sha256_format, check: "sha256 ~ '^[0-9a-f]{64}$'")
  end
end
