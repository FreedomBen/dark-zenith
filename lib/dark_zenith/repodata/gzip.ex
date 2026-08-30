defmodule DarkZenith.Repodata.Gzip do
  @moduledoc """
  Deterministic gzip for metadata artifacts: compression level 6, `mtime` 0,
  and no original filename stored in the gzip header (DESIGN.md: Metadata
  Format), so identical XML input always yields identical compressed bytes.
  """

  @doc "Compresses iodata to a gzip binary deterministically."
  def compress(iodata) do
    z = :zlib.open()

    try do
      # windowBits 31 = 15 + 16 selects the gzip wrapper; zlib's default gzip
      # header carries mtime 0 and no name/comment fields.
      :ok = :zlib.deflateInit(z, 6, :deflated, 31, 8, :default)
      compressed = :zlib.deflate(z, iodata, :finish)
      :ok = :zlib.deflateEnd(z)
      IO.iodata_to_binary(compressed)
    after
      :zlib.close(z)
    end
  end
end
