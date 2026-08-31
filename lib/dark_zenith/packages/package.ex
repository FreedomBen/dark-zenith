defmodule DarkZenith.Packages.Package do
  @moduledoc """
  One RPM file within a repository (DESIGN.md: Data Model — Packages).

  Dependency, file, and changelog collections are stored in jsonb using the
  documented nested-entry shapes produced by `DarkZenith.Rpm.Extractor`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "packages" do
    field :rpm_format, :integer
    field :name, :string
    field :epoch, :integer, default: 0
    field :version, :string
    field :release, :string
    field :arch, :string
    field :summary, :string
    field :description, :string
    field :url, :string
    field :license, :string
    field :size_installed, :integer
    field :size_package, :integer
    field :size_archive, :integer
    field :sha256, :string
    field :build_time, :utc_datetime
    field :rpm_sourcerpm, :string
    field :rpm_sourcenevr, :string
    field :rpm_group, :string
    field :rpm_vendor, :string
    field :rpm_buildhost, :string
    field :header_start, :integer
    field :header_end, :integer
    field :storage_path, :string
    field :storage_version_id, :string
    field :requires, {:array, :map}, default: []
    field :provides, {:array, :map}, default: []
    field :conflicts, {:array, :map}, default: []
    field :obsoletes, {:array, :map}, default: []
    field :recommends, {:array, :map}, default: []
    field :suggests, {:array, :map}, default: []
    field :supplements, {:array, :map}, default: []
    field :enhances, {:array, :map}, default: []
    field :files, {:array, :map}, default: []
    field :changelogs, {:array, :map}, default: []

    belongs_to :repository, DarkZenith.Repositories.Repository

    timestamps(type: :utc_datetime)
  end
end
