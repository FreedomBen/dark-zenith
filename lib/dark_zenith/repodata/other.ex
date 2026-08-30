defmodule DarkZenith.Repodata.Other do
  @moduledoc """
  `other.xml` (changelogs) encoder (DESIGN.md: Metadata Format).
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
      ~s(<otherdata xmlns="http://linux.duke.edu/metadata/other" packages="#{count}">\n)
    ]
  end

  @doc "Document epilogue."
  def epilogue, do: "</otherdata>\n"

  defp package_entry(package) do
    raise ArgumentError,
          "other.xml package entries are not implemented yet: #{inspect(package)}"
  end
end
