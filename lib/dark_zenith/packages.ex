defmodule DarkZenith.Packages do
  @moduledoc """
  The Packages context (DESIGN.md: Data Model — Packages). Creation and
  deletion arrive with the upload pipeline; this module carries the pieces
  metadata generation needs.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Packages.Package
  alias DarkZenith.Rpm.Metadata

  @doc """
  Package-row attributes extracted from parsed RPM metadata. The caller adds
  the storage/identity fields the parser cannot know (`sha256`,
  `size_package`, `storage_path`, `storage_version_id`, `repository_id`).
  """
  def metadata_attrs(%Metadata{} = m) do
    %{
      rpm_format: m.rpm_format,
      name: m.name,
      epoch: m.epoch,
      version: m.version,
      release: m.release,
      arch: m.arch,
      summary: m.summary,
      description: m.description,
      url: m.url,
      license: m.license,
      size_installed: m.size_installed,
      size_archive: m.size_archive,
      build_time: m.build_time,
      rpm_sourcerpm: m.rpm_sourcerpm,
      rpm_sourcenevr: m.rpm_sourcenevr,
      rpm_group: m.rpm_group,
      rpm_vendor: m.rpm_vendor,
      rpm_buildhost: m.rpm_buildhost,
      header_start: m.header_start,
      header_end: m.header_end,
      requires: m.requires,
      provides: m.provides,
      conflicts: m.conflicts,
      obsoletes: m.obsoletes,
      recommends: m.recommends,
      suggests: m.suggests,
      supplements: m.supplements,
      enhances: m.enhances,
      files: m.files,
      changelogs: m.changelogs
    }
  end

  @doc """
  All packages of a repository in the deterministic snapshot order used by
  metadata regeneration: `name`, `epoch`, `version`, `release`, `arch`, `id`
  (DESIGN.md: Metadata Generation & Storage step 3).
  """
  def snapshot_query(repository_id) do
    from p in Package,
      where: p.repository_id == ^repository_id,
      order_by: [asc: p.name, asc: p.epoch, asc: p.version, asc: p.release, asc: p.arch, asc: p.id]
  end
end
