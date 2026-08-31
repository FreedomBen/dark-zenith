defmodule DarkZenith.Rpm.Metadata do
  @moduledoc """
  Metadata extracted from one RPM package (DESIGN.md: Package Upload &
  Processing step 3). Collection entries use the documented JSON shapes so
  they can be stored in the package row's jsonb columns verbatim.
  """

  defstruct [
    :rpm_format,
    :name,
    :epoch,
    :version,
    :release,
    :arch,
    :summary,
    :description,
    :license,
    :url,
    :rpm_group,
    :rpm_vendor,
    :rpm_buildhost,
    :rpm_sourcerpm,
    :rpm_sourcenevr,
    :size_installed,
    :size_archive,
    :build_time,
    :source_package?,
    :header_start,
    :header_end,
    requires: [],
    provides: [],
    conflicts: [],
    obsoletes: [],
    recommends: [],
    suggests: [],
    supplements: [],
    enhances: [],
    files: [],
    changelogs: []
  ]
end
