defmodule DarkZenith.Repodata.Primary do
  @moduledoc """
  `primary.xml` encoder (DESIGN.md: Metadata Format). Emitted incrementally as
  prologue, per-package entries, and epilogue so callers can stream to a file
  or a counting sink.

  Package entries match `createrepo_c` byte-for-byte inside `<format>`; the
  documented deviations are the `location` href (`packages/:id/...`), `time
  file=` from `inserted_at`, no `<packager>`, and null optional elements
  omitted rather than emitted empty.
  """

  alias DarkZenith.Repodata.XML

  @doc "Encodes the complete document for the given packages as iodata."
  def encode(packages) do
    [prologue(length(packages)), Enum.map(packages, &entry/1), epilogue()]
  end

  @doc "Document prologue carrying the package count."
  def prologue(count) do
    [
      XML.declaration(),
      ~s(<metadata xmlns="http://linux.duke.edu/metadata/common" ),
      ~s(xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="#{count}">\n)
    ]
  end

  @doc "Document epilogue."
  def epilogue, do: "</metadata>\n"

  @doc "One package's `<package>` element as iodata."
  def entry(package) do
    file_time = DateTime.to_unix(package.inserted_at)
    build_time = if package.build_time, do: DateTime.to_unix(package.build_time), else: file_time

    [
      ~s(<package type="rpm">\n),
      element("  ", "name", package.name),
      element("  ", "arch", package.arch),
      version_element("  ", package),
      ["  <checksum type=\"sha256\" pkgid=\"YES\">", XML.escape(package.sha256), "</checksum>\n"],
      element("  ", "summary", package.summary),
      element("  ", "description", package.description),
      optional_element("  ", "url", package.url),
      [~s(  <time file="#{file_time}" build="#{build_time}"/>\n)],
      size_element(package),
      location_element(package),
      "  <format>\n",
      element("    ", "rpm:license", package.license),
      optional_element("    ", "rpm:vendor", package.rpm_vendor),
      optional_element("    ", "rpm:group", package.rpm_group),
      optional_element("    ", "rpm:buildhost", package.rpm_buildhost),
      optional_element("    ", "rpm:sourcerpm", package.rpm_sourcerpm),
      [~s(    <rpm:header-range start="#{package.header_start}" end="#{package.header_end}"/>\n)],
      dep_element("rpm:provides", package.provides),
      dep_element("rpm:requires", package.requires),
      dep_element("rpm:conflicts", package.conflicts),
      dep_element("rpm:obsoletes", package.obsoletes),
      dep_element("rpm:suggests", package.suggests),
      dep_element("rpm:enhances", package.enhances),
      dep_element("rpm:recommends", package.recommends),
      dep_element("rpm:supplements", package.supplements),
      primary_files(package.files),
      "  </format>\n",
      "</package>\n"
    ]
  end

  defp element(indent, tag, value) do
    [indent, "<", tag, ">", XML.escape(value), "</", tag, ">\n"]
  end

  defp optional_element(_indent, _tag, nil), do: []
  defp optional_element(indent, tag, value), do: element(indent, tag, value)

  defp version_element(indent, package) do
    [
      indent,
      ~s(<version epoch="#{package.epoch}" ver="),
      XML.escape(package.version),
      ~s(" rel="),
      XML.escape(package.release),
      ~s("/>\n)
    ]
  end

  # The archive attribute is omitted when size_archive is null; dnf/libsolv
  # reads each size attribute independently.
  defp size_element(package) do
    archive =
      if package.size_archive, do: ~s( archive="#{package.size_archive}"), else: ""

    [
      ~s(  <size package="#{package.size_package}" installed="#{package.size_installed}"),
      archive,
      "/>\n"
    ]
  end

  # location href is the relative standard-filename path keyed by package
  # UUID; NEVRA fields are already restricted to URL-safe characters.
  defp location_element(package) do
    [
      ~s(  <location href="packages/),
      package.id,
      "/",
      XML.escape(package.name),
      "-",
      XML.escape(package.version),
      "-",
      XML.escape(package.release),
      ".",
      XML.escape(package.arch),
      ~s(.rpm"/>\n)
    ]
  end

  # A dependency element whose list is empty is omitted entirely.
  defp dep_element(_tag, []), do: []

  defp dep_element(tag, entries) do
    [
      "    <",
      tag,
      ">\n",
      Enum.map(entries, &dep_entry/1),
      "    </",
      tag,
      ">\n"
    ]
  end

  defp dep_entry(entry) do
    versioned =
      if entry["op"] do
        release =
          if entry["release"], do: [~s( rel="), XML.escape(entry["release"]), ~s(")], else: []

        [
          ~s( flags="#{op_to_flags(entry["op"])}" epoch="#{entry["epoch"]}" ver="),
          XML.escape(entry["version"]),
          ~s("),
          release
        ]
      else
        []
      end

    pre = if entry["pre"], do: ~s( pre="1"), else: ""

    [~s(      <rpm:entry name="), XML.escape(entry["name"]), ~s("), versioned, pre, "/>\n"]
  end

  defp op_to_flags("="), do: "EQ"
  defp op_to_flags("<"), do: "LT"
  defp op_to_flags("<="), do: "LE"
  defp op_to_flags(">"), do: "GT"
  defp op_to_flags(">="), do: "GE"

  # The standard primary files subset: paths under /etc/, paths containing
  # bin/, and /usr/lib/sendmail, with the filelists type mapping.
  defp primary_files(files) do
    for file <- files, primary_path?(file["path"]) do
      [
        "    <file",
        DarkZenith.Repodata.Filelists.type_attribute(file),
        ">",
        XML.escape(file["path"]),
        "</file>\n"
      ]
    end
  end

  defp primary_path?(path) do
    String.starts_with?(path, "/etc/") or String.contains?(path, "bin/") or
      path == "/usr/lib/sendmail"
  end
end
