defmodule DarkZenith.Repodata.Filelists do
  @moduledoc """
  `filelists.xml` encoder (DESIGN.md: Metadata Format). File entries carry
  `type="dir"` for directories and `type="ghost"` for non-directory entries
  with the ghost flag; directory mode takes precedence.
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
      ~s(<filelists xmlns="http://linux.duke.edu/metadata/filelists" packages="#{count}">\n)
    ]
  end

  @doc "Document epilogue."
  def epilogue, do: "</filelists>\n"

  @doc "One package's `<package>` element as iodata."
  def entry(package) do
    [
      package_open(package),
      version_element(package),
      Enum.map(package.files, fn file ->
        ["  <file", type_attribute(file), ">", XML.escape(file["path"]), "</file>\n"]
      end),
      "</package>\n"
    ]
  end

  @doc false
  def package_open(package) do
    [
      ~s(<package pkgid="),
      XML.escape(package.sha256),
      ~s(" name="),
      XML.escape(package.name),
      ~s(" arch="),
      XML.escape(package.arch),
      ~s(">\n)
    ]
  end

  @doc false
  def version_element(package) do
    [
      ~s(  <version epoch="#{package.epoch}" ver="),
      XML.escape(package.version),
      ~s(" rel="),
      XML.escape(package.release),
      ~s("/>\n)
    ]
  end

  @doc "The type attribute for a file entry (also used by primary.xml)."
  def type_attribute(file) do
    cond do
      file["type"] == "directory" -> ~s( type="dir")
      "ghost" in (file["flags"] || []) -> ~s( type="ghost")
      true -> ""
    end
  end
end
