defmodule DarkZenith.Repodata do
  @moduledoc """
  Repository metadata (`repodata/`) generation — DESIGN.md: Metadata Format;
  Metadata Generation & Storage.

  All artifacts are deterministic for identical inputs: the XML encoders emit
  a canonical byte form and gzip output is fixed (level 6, zero mtime, no
  original filename). A release that changes the XML serialization must ship a
  migration recalculating the maintained repository size counters.
  """

  alias DarkZenith.Repodata.{Filelists, Gzip, Other, Primary, Repomd}

  defmodule Generation do
    @moduledoc "One complete generated metadata set."

    @enforce_keys [
      :primary_xml_gz,
      :filelists_xml_gz,
      :other_xml_gz,
      :repomd_xml,
      :open_sizes,
      :revision,
      :timestamp
    ]
    defstruct @enforce_keys
  end

  @doc """
  Generates the complete metadata set for the given packages.

  Options:

    * `:revision` — the repository `metadata_revision` this generation ran
      against; written to `<revision>` (a deliberate deviation from
      createrepo_c's Unix timestamp there)
    * `:timestamp` — one UTC generation timestamp in whole seconds, used for
      all three `repomd.xml` data entries
  """
  def generate(packages, opts) do
    revision = Keyword.fetch!(opts, :revision)
    timestamp = Keyword.fetch!(opts, :timestamp)

    artifacts =
      for {type, encoder} <- [primary: Primary, filelists: Filelists, other: Other] do
        open_iodata = encoder.encode(packages)
        open_binary = IO.iodata_to_binary(open_iodata)
        compressed = Gzip.compress(open_binary)

        {type,
         %{
           compressed: compressed,
           open_size: byte_size(open_binary),
           open_checksum: sha256_hex(open_binary),
           size: byte_size(compressed),
           checksum: sha256_hex(compressed),
           timestamp: timestamp
         }}
      end

    %Generation{
      primary_xml_gz: artifacts[:primary].compressed,
      filelists_xml_gz: artifacts[:filelists].compressed,
      other_xml_gz: artifacts[:other].compressed,
      repomd_xml: IO.iodata_to_binary(Repomd.encode(artifacts, revision)),
      open_sizes: %{
        primary: artifacts[:primary].open_size,
        filelists: artifacts[:filelists].open_size,
        other: artifacts[:other].open_size
      },
      revision: revision,
      timestamp: timestamp
    }
  end

  defp sha256_hex(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
