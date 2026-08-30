defmodule DarkZenith.Repodata.Primary do
  @moduledoc """
  `primary.xml` encoder (DESIGN.md: Metadata Format). Emitted incrementally as
  prologue, per-package entries, and epilogue so callers can stream to a file
  or a counting sink.
  """

  alias DarkZenith.Repodata.XML

  @doc "Encodes the complete document for the given packages as iodata."
  def encode(packages) do
    [prologue(length(packages)), Enum.map(packages, &package_entry/1), epilogue()]
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

  # Per-package entries arrive with the package pipeline (Phase 6).
  defp package_entry(package) do
    raise ArgumentError,
          "primary.xml package entries are not implemented yet: #{inspect(package)}"
  end
end
