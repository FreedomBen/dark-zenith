defmodule DarkZenith.Rpm.ParserTest do
  use ExUnit.Case, async: true

  import DarkZenith.RpmFixtures

  alias DarkZenith.Rpm.Parser

  describe "accepted packages" do
    test "parses the v4 fixture with the createrepo_c header range" do
      assert {:ok, parsed} = Parser.parse(v4_binary())
      assert parsed.format == 4
      # header-range from createrepo_c primary.xml: start=4504 end=7977
      assert parsed.header_start == 4504
      assert parsed.header_end == 7977
    end

    test "parses the v6 fixture" do
      assert {:ok, parsed} = Parser.parse(v6_binary())
      assert parsed.format == 6
      assert parsed.header_start == 4456
      assert parsed.header_end == 8364
    end

    test "parses the source package as v4" do
      assert {:ok, parsed} = Parser.parse(v4_source_binary())
      assert parsed.format == 4
    end

    test "parses the minimal fixture with the createrepo_c header range" do
      assert {:ok, parsed} = Parser.parse(minimal_binary())
      assert parsed.header_start == 4504
      assert parsed.header_end == 6033
    end
  end

  describe "lead and gross structure" do
    test "rejects a bad lead magic" do
      assert {:error, :bad_lead_magic} = Parser.parse(patch(v4_binary(), 0, <<0xDE, 0xAD>>))
    end

    test "rejects truncated files" do
      assert {:error, :truncated} = Parser.parse(binary_part(v4_binary(), 0, 50))
      assert {:error, :truncated} = Parser.parse(binary_part(v4_binary(), 0, 100))
      assert {:error, :truncated} = Parser.parse(binary_part(v4_binary(), 0, 4600))
    end

    test "rejects a bad signature header magic" do
      assert {:error, :bad_header_magic} = Parser.parse(patch(v4_binary(), 96, <<0xFF>>))
    end

    test "rejects headers with more than 65535 index entries" do
      # Patch the signature header nindex to 65 536.
      bad = patch(v4_binary(), 96 + 8, <<65_536::32>>)
      assert {:error, :too_many_entries} = Parser.parse(bad)
    end

    test "rejects headers whose combined size exceeds 64 MiB" do
      # Claim a giant data store; the bound check fires before any read.
      bad = patch(v4_binary(), 96 + 12, <<70_000_000::32>>)
      assert {:error, :header_too_large} = Parser.parse(bad)
    end
  end

  describe "index entry invariants" do
    test "rejects duplicate tag numbers" do
      binary = v4_binary()
      main = main_header_offset(binary)
      # VENDOR (1011) -> LICENSE (1014), duplicating LICENSE.
      index = find_entry(binary, main, 1011)
      bad = patch_entry(binary, main, index, tag: 1014)
      assert {:error, :duplicate_tag} = Parser.parse(bad)
    end

    test "rejects out-of-bounds data references" do
      binary = v4_binary()
      main = main_header_offset(binary)
      {_nindex, hsize} = header_counts(binary, main)
      index = find_entry(binary, main, 1000)
      bad = patch_entry(binary, main, index, offset: hsize + 10)
      assert {:error, :entry_out_of_bounds} = Parser.parse(bad)
    end

    test "rejects unknown entry types" do
      binary = v4_binary()
      main = main_header_offset(binary)
      index = find_entry(binary, main, 1000)
      bad = patch_entry(binary, main, index, type: 12)
      assert {:error, :unknown_entry_type} = Parser.parse(bad)
    end

    test "rejects misaligned numeric data references" do
      binary = v4_binary()
      main = main_header_offset(binary)
      # BUILDTIME (1006) is INT32; knock its offset off 4-byte alignment.
      index = find_entry(binary, main, 1006)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, main + 16 + index * 16, 16)

      bad = patch_entry(binary, main, index, offset: offset + 1)
      assert {:error, error} = Parser.parse(bad)
      assert error in [:misaligned_entry, :overlapping_entries]
    end

    test "rejects overlapping data references" do
      binary = v4_binary()
      main = main_header_offset(binary)
      # Point NAME (1000) into VERSION's (1001) data.
      version_index = find_entry(binary, main, 1001)

      <<_t::32, _ty::32, version_offset::32, _c::32>> =
        binary_part(binary, main + 16 + version_index * 16, 16)

      name_index = find_entry(binary, main, 1000)
      bad = patch_entry(binary, main, name_index, offset: version_offset)
      assert {:error, :overlapping_entries} = Parser.parse(bad)
    end

    test "rejects a main header without the immutable region (v3 shape)" do
      binary = v4_binary()
      main = main_header_offset(binary)
      bad = patch_entry(binary, main, 0, tag: 61)
      assert {:error, :missing_region} = Parser.parse(bad)
    end
  end

  describe "v4 digest requirements" do
    test "rejects a v4 package without the SHA-256 header digest" do
      binary = v4_binary()
      index = find_entry(binary, 96, 273)
      # Retag the digest entry so SHA256HEADER is absent (weak-only package).
      bad = patch_entry(binary, 96, index, tag: 998)
      assert {:error, :weak_digests} = Parser.parse(bad)
    end

    test "rejects a v4 package without the SHA-256 payload digest" do
      binary = v4_binary()
      main = main_header_offset(binary)
      index = find_entry(binary, main, 5092)
      bad = patch_entry(binary, main, index, tag: 5091)
      assert {:error, :weak_digests} = Parser.parse(bad)
    end

    test "rejects a v4 package whose payload digest algorithm is not SHA-256" do
      binary = v4_binary()
      main = main_header_offset(binary)
      {nindex, _} = header_counts(binary, main)
      index = find_entry(binary, main, 5093)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, main + 16 + index * 16, 16)

      # PAYLOADDIGESTALGO value 8 (SHA-256) -> 2 (SHA-1).
      data_start = main + 16 + nindex * 16
      bad = patch(binary, data_start + offset, <<2::32>>)
      assert {:error, :weak_digests} = Parser.parse(bad)
    end
  end

  describe "v6 format requirements" do
    test "rejects unsorted v6 header entries" do
      binary = v6_binary()
      main = main_header_offset(binary)
      # Swap the tags of two consecutive non-region entries.
      <<t1::32, ty1::32, o1::32, c1::32>> = binary_part(binary, main + 16 + 16, 16)
      <<t2::32, ty2::32, o2::32, c2::32>> = binary_part(binary, main + 16 + 32, 16)

      bad =
        binary
        |> patch(main + 16 + 16, <<t2::32, ty2::32, o2::32, c2::32>>)
        |> patch(main + 16 + 32, <<t1::32, ty1::32, o1::32, c1::32>>)

      assert {:error, :unsorted_tags} = Parser.parse(bad)
    end

    test "rejects a v6 signature with a tag above 999" do
      binary = v6_binary()
      # RESERVED (999) -> 1004 keeps the entries sorted but crosses the cap.
      index = find_entry(binary, 96, 999)
      bad = patch_entry(binary, 96, index, tag: 1004)
      assert {:error, :v6_signature_forbidden_tag} = Parser.parse(bad)
    end

    test "rejects a v6 signature missing the SHA3-256 digest" do
      binary = v6_binary()
      index = find_entry(binary, 96, 279)
      bad = patch_entry(binary, 96, index, tag: 278)
      assert {:error, :v6_signature_missing_digest} = Parser.parse(bad)
    end

    test "rejects a v6 signature whose RESERVED entry is not zero-filled" do
      binary = v6_binary()
      {nindex, _} = header_counts(binary, 96)
      index = find_entry(binary, 96, 999)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, 96 + 16 + index * 16, 16)

      data_start = 96 + 16 + nindex * 16
      bad = patch(binary, data_start + offset + 5, <<1>>)
      assert {:error, :v6_reserved_not_zero} = Parser.parse(bad)
    end

    test "rejects a v6 main header missing the uncompressed payload size" do
      binary = v6_binary()
      main = main_header_offset(binary)
      # PAYLOADSIZE (5112) -> unused 5111 keeps the entries sorted.
      index = find_entry(binary, main, 5112)
      bad = patch_entry(binary, main, index, tag: 5111)
      assert {:error, :v6_missing_mandatory_tag} = Parser.parse(bad)
    end

    test "rejects a v6 main header missing ENCODING" do
      binary = v6_binary()
      main = main_header_offset(binary)
      # ENCODING (5062) -> unused 5058 keeps the entries sorted.
      index = find_entry(binary, main, 5062)
      bad = patch_entry(binary, main, index, tag: 5058)
      assert {:error, :v6_missing_mandatory_tag} = Parser.parse(bad)
    end

    test "rejects an unknown RPMFORMAT value" do
      binary = v6_binary()
      main = main_header_offset(binary)
      {nindex, _} = header_counts(binary, main)
      index = find_entry(binary, main, 5114)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, main + 16 + index * 16, 16)

      data_start = main + 16 + nindex * 16
      bad = patch(binary, data_start + offset, <<5::32>>)
      assert {:error, :unsupported_format} = Parser.parse(bad)
    end
  end
end
