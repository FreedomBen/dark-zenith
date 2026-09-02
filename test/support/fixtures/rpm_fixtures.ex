defmodule DarkZenith.RpmFixtures do
  @moduledoc """
  Reads the checked-in fixture RPMs and derives malformed/weak variants by
  byte-patching them (see `test/support/fixtures/rpms/README.md`).
  """

  @fixtures_dir Path.expand("rpms", __DIR__)

  def rpm_binary(name) do
    File.read!(Path.join(@fixtures_dir, name))
  end

  def v4_binary, do: rpm_binary("dz-fixture-v4.rpm")
  def v6_binary, do: rpm_binary("dz-fixture-v6.rpm")
  def v4_source_binary, do: rpm_binary("dz-fixture-v4.src.rpm")
  def minimal_binary, do: rpm_binary("dz-minimal-v4.rpm")

  @doc "A real-world unsigned x86_64 package built outside rpmbuild (see the README)."
  def paladin_binary, do: rpm_binary("paladin-0.1.0-1.x86_64.rpm")

  @doc "Replaces `byte_size(replacement)` bytes at `offset`."
  def patch(binary, offset, replacement) when is_binary(replacement) do
    <<prefix::binary-size(offset), _::binary-size(byte_size(replacement)), rest::binary>> =
      binary

    prefix <> replacement <> rest
  end

  @doc """
  Patches one 16-byte index entry of the header starting at `header_offset`
  (0-based entry index). `fields` may set `:tag`, `:type`, `:offset`,
  `:count`; unset fields keep their current value.
  """
  def patch_entry(binary, header_offset, index, fields) do
    entry_offset = header_offset + 16 + index * 16

    <<tag::signed-32, type::32, offset::32, count::32>> =
      binary_part(binary, entry_offset, 16)

    tag = Keyword.get(fields, :tag, tag)
    type = Keyword.get(fields, :type, type)
    offset = Keyword.get(fields, :offset, offset)
    count = Keyword.get(fields, :count, count)

    patch(binary, entry_offset, <<tag::signed-32, type::32, offset::32, count::32>>)
  end

  @doc "Reads `{nindex, hsize}` of the header starting at `header_offset`."
  def header_counts(binary, header_offset) do
    <<_magic::binary-4, _reserved::binary-4, nindex::32, hsize::32>> =
      binary_part(binary, header_offset, 16)

    {nindex, hsize}
  end

  @doc """
  Finds the 0-based index-entry position of `tag` in the header starting at
  `header_offset`, or nil.
  """
  def find_entry(binary, header_offset, tag) do
    {nindex, _hsize} = header_counts(binary, header_offset)

    Enum.find(0..(nindex - 1), fn i ->
      <<found::signed-32, _::binary>> = binary_part(binary, header_offset + 16 + i * 16, 16)
      found == tag
    end)
  end

  @doc "Offset of the main header, assuming a valid signature header at 96."
  def main_header_offset(binary) do
    {nindex, hsize} = header_counts(binary, 96)
    sig_end = 96 + 16 + nindex * 16 + hsize
    sig_end + rem(8 - rem(sig_end, 8), 8)
  end
end
