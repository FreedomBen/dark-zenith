defmodule DarkZenith.Repodata.Other do
  @moduledoc """
  `other.xml` (changelogs) encoder (DESIGN.md: Metadata Format).

  Emits the first 10 changelog entries in RPM header order (the 10 most
  recent, since rpmbuild writes the header newest-first), written
  oldest-first with non-increasing dates bumped one second past their
  predecessor — reproducing `createrepo_c`'s strictly increasing output
  dates. The stored package row keeps the raw entries and timestamps.
  """

  alias DarkZenith.Repodata.{Filelists, XML}

  @changelog_limit 10

  @doc "Encodes the complete document for the given packages as iodata."
  def encode(packages) do
    [prologue(length(packages)), Enum.map(packages, &entry/1), epilogue()]
  end

  @doc "Document prologue carrying the package count."
  def prologue(count) do
    [
      XML.declaration(),
      ~s(<otherdata xmlns="http://linux.duke.edu/metadata/other" packages="#{count}">\n)
    ]
  end

  @doc "Document epilogue."
  def epilogue, do: "</otherdata>\n"

  @doc "One package's `<package>` element as iodata."
  def entry(package) do
    [
      Filelists.package_open(package),
      Filelists.version_element(package),
      changelog_entries(package.changelogs),
      "</package>\n"
    ]
  end

  defp changelog_entries(changelogs) do
    changelogs
    |> Enum.take(@changelog_limit)
    |> Enum.reverse()
    |> Enum.map_reduce(nil, fn entry, previous_date ->
      date = entry_date(entry)
      date = if previous_date && date <= previous_date, do: previous_date + 1, else: date

      iodata = [
        ~s(  <changelog author="),
        XML.escape(entry["author"]),
        ~s(" date="#{date}">),
        XML.escape(entry["text"]),
        "</changelog>\n"
      ]

      {iodata, date}
    end)
    |> elem(0)
  end

  defp entry_date(entry) do
    {:ok, datetime, 0} = DateTime.from_iso8601(entry["timestamp"])
    DateTime.to_unix(datetime)
  end
end
