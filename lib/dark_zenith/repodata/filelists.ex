defmodule DarkZenith.Repodata.Filelists do
  @moduledoc """
  `filelists.xml` encoder (DESIGN.md: Metadata Format).
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
      ~s(<filelists xmlns="http://linux.duke.edu/metadata/filelists" packages="#{count}">\n)
    ]
  end

  @doc "Document epilogue."
  def epilogue, do: "</filelists>\n"

  defp package_entry(package) do
    raise ArgumentError,
          "filelists.xml package entries are not implemented yet: #{inspect(package)}"
  end
end
