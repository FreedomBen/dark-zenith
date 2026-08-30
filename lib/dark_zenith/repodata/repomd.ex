defmodule DarkZenith.Repodata.Repomd do
  @moduledoc """
  `repomd.xml` encoder (DESIGN.md: Metadata Format).

  `<revision>` carries the repository `metadata_revision` the generation ran
  against — a deliberate deviation from createrepo_c's Unix timestamp, since
  dnf/librepo treat it as an opaque string and a monotonic revision makes
  cache staleness checkable against `source_revision`.
  """

  alias DarkZenith.Repodata.XML

  @doc """
  Encodes `repomd.xml` as iodata from `[{type, artifact}]` entries, where each
  artifact carries `:checksum`, `:open_checksum`, `:size`, `:open_size`, and
  `:timestamp`.
  """
  def encode(artifacts, revision) do
    [
      XML.declaration(),
      ~s(<repomd xmlns="http://linux.duke.edu/metadata/repo">\n),
      "  <revision>",
      XML.escape(to_string(revision)),
      "</revision>\n",
      Enum.map(artifacts, &data_entry/1),
      "</repomd>\n"
    ]
  end

  defp data_entry({type, artifact}) do
    type = to_string(type)

    [
      ~s(  <data type="#{type}">\n),
      ~s(    <checksum type="sha256">#{artifact.checksum}</checksum>\n),
      ~s(    <open-checksum type="sha256">#{artifact.open_checksum}</open-checksum>\n),
      ~s(    <location href="repodata/#{type}.xml.gz"/>\n),
      ~s(    <timestamp>#{artifact.timestamp}</timestamp>\n),
      ~s(    <size>#{artifact.size}</size>\n),
      ~s(    <open-size>#{artifact.open_size}</open-size>\n),
      ~s(  </data>\n)
    ]
  end
end
