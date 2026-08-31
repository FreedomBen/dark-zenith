defmodule DarkZenith.Rpm.ExtractorTest do
  use ExUnit.Case, async: true

  import DarkZenith.RpmFixtures

  alias DarkZenith.Rpm
  alias DarkZenith.Rpm.{Header, Parser, Tags}

  describe "v4 fixture extraction" do
    setup do
      {:ok, metadata} = Rpm.parse(v4_binary())
      %{m: metadata}
    end

    test "NEVRA and scalar fields match the createrepo_c reference", %{m: m} do
      assert m.rpm_format == 4
      assert m.name == "dz-fixture"
      assert m.epoch == 2
      assert m.version == "1.2.3"
      assert m.release == "4"
      assert m.arch == "noarch"
      assert m.summary == "Dark Zenith parser fixture package — ünïcode ok"
      assert m.description =~ "Fixture package for the Dark Zenith pure-Elixir RPM parser."
      assert m.description =~ "Second paragraph with a tab:\tand ünïcode."
      assert m.license == "MIT"
      assert m.url == "https://example.com/dz-fixture"
      assert m.rpm_group == "Development/Testing"
      assert m.rpm_vendor == "Dark Zenith Test Vendor"
      assert m.rpm_buildhost == "dz-fixture-builder"
      assert m.rpm_sourcerpm == "dz-fixture-1.2.3-4.src.rpm"
      assert m.rpm_sourcenevr == nil
      refute m.source_package?
    end

    test "sizes, build time, and header range", %{m: m} do
      assert m.size_installed == 48
      assert m.size_archive == 588
      assert m.build_time == DateTime.from_unix!(1_787_200_000)
      assert m.header_start == 4504
      assert m.header_end == 7977
    end

    test "requires excludes rpmlib entries and keeps header order with pre flags", %{m: m} do
      assert m.requires == [
               %{
                 "name" => "(dz-alt-a or dz-alt-b)",
                 "op" => nil,
                 "epoch" => nil,
                 "version" => nil,
                 "release" => nil,
                 "pre" => false
               },
               %{
                 "name" => "/usr/bin/sh",
                 "op" => nil,
                 "epoch" => nil,
                 "version" => nil,
                 "release" => nil,
                 "pre" => false
               },
               %{
                 "name" => "dz-data",
                 "op" => nil,
                 "epoch" => nil,
                 "version" => nil,
                 "release" => nil,
                 "pre" => false
               },
               %{
                 "name" => "dz-lib",
                 "op" => ">=",
                 "epoch" => 0,
                 "version" => "1.0",
                 "release" => nil,
                 "pre" => false
               },
               %{
                 "name" => "dz-post-tool",
                 "op" => nil,
                 "epoch" => nil,
                 "version" => nil,
                 "release" => nil,
                 "pre" => true
               },
               %{
                 "name" => "dz-pre-tool",
                 "op" => nil,
                 "epoch" => nil,
                 "version" => nil,
                 "release" => nil,
                 "pre" => true
               }
             ]
    end

    test "the other dependency lists match the createrepo_c reference", %{m: m} do
      assert [
               %{"name" => "dz-capability", "op" => "=", "epoch" => 0, "version" => "9.9"},
               %{
                 "name" => "dz-fixture",
                 "op" => "=",
                 "epoch" => 2,
                 "version" => "1.2.3",
                 "release" => "4"
               },
               %{"name" => "dz-fixture-alias", "op" => nil}
             ] = m.provides

      assert [%{"name" => "dz-old", "op" => "<", "version" => "1.0"}] = m.conflicts
      assert [%{"name" => "dz-legacy", "op" => "<=", "version" => "0.5"}] = m.obsoletes
      assert [%{"name" => "dz-nice", "op" => ">=", "version" => "2.0"}] = m.recommends
      assert [%{"name" => "dz-maybe", "op" => nil}] = m.suggests
      assert [%{"name" => "dz-parent", "op" => nil}] = m.supplements
      assert [%{"name" => "dz-extra", "op" => "=", "version" => "3.1"}] = m.enhances

      refute Map.has_key?(hd(m.provides), "pre")
    end

    test "files carry paths, types, and flags in header order", %{m: m} do
      assert m.files == [
               %{"path" => "/usr/bin/dz-fixture", "type" => "file", "flags" => []},
               %{"path" => "/usr/share/dz-fixture", "type" => "directory", "flags" => []},
               %{"path" => "/usr/share/dz-fixture/data.txt", "type" => "file", "flags" => []}
             ]
    end

    test "changelogs keep header order (newest first)", %{m: m} do
      assert [
               %{
                 "timestamp" => first_ts,
                 "author" => "Fixture Author <fixtures@example.com> - 2:1.2.3-4",
                 "text" => "- Second changelog entry with ünïcode"
               },
               %{
                 "timestamp" => second_ts,
                 "author" => "Fixture Author <fixtures@example.com> - 2:1.2.2-1",
                 "text" => "- First changelog entry"
               }
             ] = m.changelogs

      assert first_ts == DateTime.from_unix!(1_787_659_200) |> DateTime.to_iso8601()
      assert second_ts == DateTime.from_unix!(1_787_572_800) |> DateTime.to_iso8601()
    end

    test "requires differentially match the createrepo_c primary.xml reference", %{m: m} do
      xml = File.read!(Path.expand("../../support/fixtures/rpms/createrepo_c/primary.xml", __DIR__))

      [_, fixture_block] = String.split(xml, "<name>dz-fixture</name>", parts: 2)
      [requires_block] = Regex.run(~r{<rpm:requires>(.*?)</rpm:requires>}s, fixture_block, capture: :all_but_first)

      reference =
        for entry <- Regex.scan(~r{<rpm:entry (.*?)/>}, requires_block, capture: :all_but_first) do
          attrs =
            for [key, value] <-
                  Regex.scan(~r{(\w+)="([^"]*)"}, hd(entry), capture: :all_but_first),
                into: %{} do
              {key, value}
            end

          %{
            "name" => attrs["name"],
            "op" => flags_to_op(attrs["flags"]),
            "epoch" => attrs["epoch"] && String.to_integer(attrs["epoch"]),
            "version" => attrs["ver"],
            "release" => attrs["rel"],
            "pre" => attrs["pre"] == "1"
          }
        end

      assert m.requires == reference
    end
  end

  defp flags_to_op(nil), do: nil
  defp flags_to_op("EQ"), do: "="
  defp flags_to_op("LT"), do: "<"
  defp flags_to_op("LE"), do: "<="
  defp flags_to_op("GT"), do: ">"
  defp flags_to_op("GE"), do: ">="

  describe "v6 fixture extraction" do
    test "uses v6 sizes and derives sourcerpm from SOURCENEVR" do
      {:ok, m} = Rpm.parse(v6_binary())

      assert m.rpm_format == 6
      assert m.epoch == 2
      assert m.size_installed == 48
      assert m.size_archive == 224
      assert m.rpm_sourcenevr == "dz-fixture-2:1.2.3-4"
      assert m.rpm_sourcerpm == "dz-fixture-1.2.3-4.src.rpm"
    end

    test "a v6 binary package without SOURCENEVR is rejected" do
      binary = v6_binary()
      main = main_header_offset(binary)
      index = find_entry(binary, main, 5120)
      bad = patch_entry(binary, main, index, tag: 5119)
      assert {:error, :missing_sourcenevr} = Rpm.parse(bad)
    end
  end

  describe "minimal and source fixtures" do
    test "optional fields are nil and collections empty" do
      {:ok, m} = Rpm.parse(minimal_binary())

      assert m.name == "dz-minimal"
      assert m.epoch == 0
      assert m.url == nil
      assert m.rpm_vendor == nil
      assert m.rpm_group == "Unspecified"
      assert m.size_installed == 0
      assert m.size_archive == 124
      # rpmlib entries are the only requires; exclusion leaves an empty list.
      assert m.requires == []
      assert [%{"name" => "dz-minimal"}] = m.provides
      assert m.files == []
      assert m.changelogs == []
    end

    test "source packages use arch src, bare filenames, and null source refs" do
      {:ok, m} = Rpm.parse(v4_source_binary())

      assert m.source_package?
      assert m.arch == "src"
      assert m.rpm_sourcerpm == nil
      assert m.rpm_sourcenevr == nil
      assert Enum.any?(m.files, &(&1["path"] == "dz-fixture.spec"))
    end
  end

  describe "NEVRA validation" do
    test "rejects a caret in the version" do
      binary = v4_binary()
      main = main_header_offset(binary)
      {nindex, _} = header_counts(binary, main)
      index = find_entry(binary, main, 1001)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, main + 16 + index * 16, 16)

      bad = patch(binary, main + 16 + nindex * 16 + offset, "1.2^3")
      assert {:error, :invalid_nevra} = Rpm.parse(bad)
    end

    test "rejects characters outside the NEVRA charset" do
      binary = v4_binary()
      main = main_header_offset(binary)
      {nindex, _} = header_counts(binary, main)
      index = find_entry(binary, main, 1000)

      <<_t::32, _ty::32, offset::32, _c::32>> =
        binary_part(binary, main + 16 + index * 16, 16)

      bad = patch(binary, main + 16 + nindex * 16 + offset, "dz fixture")
      assert {:error, :invalid_nevra} = Rpm.parse(bad)
    end
  end

  describe "synthetic header extraction rules" do
    defp synthetic(overrides, opts \\ []) do
      values =
        Map.merge(
          %{
            Tags.name() => {:string, "pkg"},
            Tags.version() => {:string, "1.0"},
            Tags.release() => {:string, "1"},
            Tags.arch() => {:string, "x86_64"},
            Tags.summary() => {:i18n_string, ["Sum"]},
            Tags.description() => {:i18n_string, ["Desc"]},
            Tags.license() => {:string, "MIT"},
            Tags.size() => {:int32, [10]}
          },
          overrides
        )

      parsed = %Parser{
        format: Keyword.get(opts, :format, 4),
        signature: %Header{
          values: Keyword.get(opts, :signature_values, %{}),
          entries: [],
          data: <<>>,
          start: 96,
          byte_size: 0
        },
        header: %Header{values: values, entries: [], data: <<>>, start: 200, byte_size: 100},
        header_start: 200,
        header_end: 300,
        file_size: 1000
      }

      DarkZenith.Rpm.Extractor.extract(parsed)
    end

    test "collapses exact duplicate requires, preserving survivor order" do
      {:ok, m} =
        synthetic(%{
          Tags.requirename() => {:string_array, ["foo", "bar", "foo", "foo"]},
          Tags.requireflags() => {:int32, [12, 0, 12, 8]},
          Tags.requireversion() => {:string_array, ["1.0", "", "1.0", "1.0"]}
        })

      assert [
               %{"name" => "foo", "op" => ">="},
               %{"name" => "bar"},
               %{"name" => "foo", "op" => "="}
             ] = m.requires
    end

    test "excludes entries with the RPMSENSE_RPMLIB flag or an rpmlib( name" do
      {:ok, m} =
        synthetic(%{
          Tags.requirename() => {:string_array, ["rpmlib(X)", "flagged", "kept"]},
          Tags.requireflags() => {:int32, [12, 16_777_216, 0]},
          Tags.requireversion() => {:string_array, ["3.0", "", ""]}
        })

      assert [%{"name" => "kept"}] = m.requires
    end

    test "parses full EVR version constraints" do
      {:ok, m} =
        synthetic(%{
          Tags.requirename() => {:string_array, ["a", "b", "c"]},
          Tags.requireflags() => {:int32, [8, 8, 8]},
          Tags.requireversion() => {:string_array, ["3:2.0-5.fc43", "2.0-5", "2.0"]}
        })

      assert [
               %{"epoch" => 3, "version" => "2.0", "release" => "5.fc43"},
               %{"epoch" => 0, "version" => "2.0", "release" => "5"},
               %{"epoch" => 0, "version" => "2.0", "release" => nil}
             ] = m.requires
    end

    test "rejects malformed dependency shapes" do
      # Cardinality mismatch.
      assert {:error, :malformed_dependency} =
               synthetic(%{
                 Tags.requirename() => {:string_array, ["a", "b"]},
                 Tags.requireflags() => {:int32, [0]},
                 Tags.requireversion() => {:string_array, ["", ""]}
               })

      # A rich dependency carrying a version.
      assert {:error, :malformed_dependency} =
               synthetic(%{
                 Tags.requirename() => {:string_array, ["(a or b)"]},
                 Tags.requireflags() => {:int32, [8]},
                 Tags.requireversion() => {:string_array, ["1.0"]}
               })

      # A version without comparison flags.
      assert {:error, :malformed_dependency} =
               synthetic(%{
                 Tags.providename() => {:string_array, ["x"]},
                 Tags.provideflags() => {:int32, [0]},
                 Tags.provideversion() => {:string_array, ["1.0"]}
               })

      # Comparison flags without a version.
      assert {:error, :malformed_dependency} =
               synthetic(%{
                 Tags.providename() => {:string_array, ["x"]},
                 Tags.provideflags() => {:int32, [8]},
                 Tags.provideversion() => {:string_array, [""]}
               })

      # Malformed EVR strings.
      for evr <- [":1.0", "1.0-", "x:1.0", "99999999999:1.0"] do
        assert {:error, :malformed_dependency} =
                 synthetic(%{
                   Tags.requirename() => {:string_array, ["a"]},
                   Tags.requireflags() => {:int32, [8]},
                   Tags.requireversion() => {:string_array, [evr]}
                 })
      end
    end

    test "weak dependencies never carry a pre value" do
      {:ok, m} =
        synthetic(%{
          Tags.recommendname() => {:string_array, ["r"]},
          Tags.recommendflags() => {:int32, [576]},
          Tags.recommendversion() => {:string_array, [""]}
        })

      assert [entry] = m.recommends
      refute Map.has_key?(entry, "pre")
    end

    test "enforces dependency, file, and changelog caps" do
      names = List.duplicate("n", 65_537)

      assert {:error, :too_many_dependencies} =
               synthetic(%{
                 Tags.requirename() => {:string_array, names},
                 Tags.requireflags() => {:int32, List.duplicate(0, 65_537)},
                 Tags.requireversion() => {:string_array, List.duplicate("", 65_537)}
               })

      n = 262_145

      assert {:error, :too_many_files} =
               synthetic(%{
                 Tags.dirindexes() => {:int32, List.duplicate(0, n)},
                 Tags.basenames() => {:string_array, List.duplicate("f", n)},
                 Tags.dirnames() => {:string_array, ["/x/"]},
                 Tags.filemodes() => {:int16, List.duplicate(0o100644, n)},
                 Tags.fileflags() => {:int32, List.duplicate(0, n)}
               })

      n = 4_097

      assert {:error, :too_many_changelogs} =
               synthetic(%{
                 Tags.changelogtime() => {:int32, List.duplicate(1, n)},
                 Tags.changelogname() => {:string_array, List.duplicate("a", n)},
                 Tags.changelogtext() => {:string_array, List.duplicate("t", n)}
               })
    end

    test "rejects out-of-range dirindexes and mismatched file arrays" do
      assert {:error, :malformed_files} =
               synthetic(%{
                 Tags.dirindexes() => {:int32, [1]},
                 Tags.basenames() => {:string_array, ["f"]},
                 Tags.dirnames() => {:string_array, ["/x/"]},
                 Tags.filemodes() => {:int16, [0o100644]},
                 Tags.fileflags() => {:int32, [0]}
               })

      assert {:error, :malformed_files} =
               synthetic(%{
                 Tags.dirindexes() => {:int32, [0]},
                 Tags.basenames() => {:string_array, ["f", "g"]},
                 Tags.dirnames() => {:string_array, ["/x/"]},
                 Tags.filemodes() => {:int16, [0o100644]},
                 Tags.fileflags() => {:int32, [0]}
               })
    end

    test "maps file modes and flags" do
      {:ok, m} =
        synthetic(%{
          Tags.dirindexes() => {:int32, [0, 0, 0]},
          Tags.basenames() => {:string_array, ["link", "ghost", "conf"]},
          Tags.dirnames() => {:string_array, ["/x/"]},
          Tags.filemodes() => {:int16, [0o120777, 0o100644, 0o100600]},
          Tags.fileflags() => {:int32, [0, 64, 1 + 2 + 128 + 256]}
        })

      assert [
               %{"path" => "/x/link", "type" => "symlink", "flags" => []},
               %{"path" => "/x/ghost", "type" => "file", "flags" => ["ghost"]},
               %{
                 "path" => "/x/conf",
                 "type" => "file",
                 "flags" => ["config", "doc", "license", "readme"]
               }
             ] = m.files
    end

    test "rejects mismatched changelog arrays" do
      assert {:error, :malformed_changelogs} =
               synthetic(%{
                 Tags.changelogtime() => {:int32, [1, 2]},
                 Tags.changelogname() => {:string_array, ["a"]},
                 Tags.changelogtext() => {:string_array, ["t", "u"]}
               })
    end

    test "i18n strings select the C entry and fall back to the first" do
      {:ok, m} =
        synthetic(%{
          Tags.i18n_table() => {:string_array, ["de", "C"]},
          Tags.summary() => {:i18n_string, ["Hallo", "Hello"]},
          Tags.description() => {:i18n_string, ["De", "En"]}
        })

      assert m.summary == "Hello"
      assert m.description == "En"

      {:ok, m} =
        synthetic(%{
          Tags.i18n_table() => {:string_array, ["de", "fr"]},
          Tags.summary() => {:i18n_string, ["Hallo", "Bonjour"]},
          Tags.description() => {:i18n_string, ["De", "Fr"]}
        })

      assert m.summary == "Hallo"
    end

    test "rejects inconsistent i18n locale/value counts" do
      assert {:error, :malformed_i18n} =
               synthetic(%{
                 Tags.i18n_table() => {:string_array, ["C", "de"]},
                 Tags.summary() => {:i18n_string, ["only-one"]}
               })
    end

    test "validates string content rules" do
      # Control character in a single-line field.
      assert {:error, :invalid_string} =
               synthetic(%{Tags.summary() => {:i18n_string, ["bad\x01"]}})

      # Carriage return in the description (only \n and \t are allowed).
      assert {:error, :invalid_string} =
               synthetic(%{Tags.description() => {:i18n_string, ["a\r\nb"]}})

      # Newlines and tabs are fine in the description.
      assert {:ok, _} = synthetic(%{Tags.description() => {:i18n_string, ["a\nb\tc"]}})

      # Invalid UTF-8 anywhere is rejected.
      assert {:error, :invalid_string} =
               synthetic(%{Tags.description() => {:i18n_string, [<<0xFF, 0xFE>>]}})

      assert {:error, :invalid_string} =
               synthetic(%{
                 Tags.requirename() => {:string_array, [<<0xC3, 0x28>>]},
                 Tags.requireflags() => {:int32, [0]},
                 Tags.requireversion() => {:string_array, [""]}
               })
    end

    test "validates the url field" do
      assert {:error, :invalid_url} = synthetic(%{Tags.url() => {:string, "ftp://example.com"}})
      assert {:error, :invalid_url} = synthetic(%{Tags.url() => {:string, "not a url"}})

      {:ok, m} = synthetic(%{Tags.url() => {:string, "   "}})
      assert m.url == nil

      {:ok, m} = synthetic(%{Tags.url() => {:string, "http://example.com/x"}})
      assert m.url == "http://example.com/x"
    end

    test "rejects missing required fields" do
      values = %{
        Tags.name() => {:string, "pkg"},
        Tags.version() => {:string, "1.0"},
        Tags.release() => {:string, "1"},
        Tags.arch() => {:string, "x86_64"},
        Tags.summary() => {:i18n_string, ["Sum"]},
        Tags.description() => {:i18n_string, ["Desc"]},
        Tags.license() => {:string, "MIT"},
        Tags.size() => {:int32, [10]}
      }

      for missing <- Map.keys(values) do
        parsed = %Parser{
          format: 4,
          signature: %Header{values: %{}, entries: [], data: <<>>, start: 96, byte_size: 0},
          header: %Header{
            values: Map.delete(values, missing),
            entries: [],
            data: <<>>,
            start: 200,
            byte_size: 100
          },
          header_start: 200,
          header_end: 300,
          file_size: 1000
        }

        assert {:error, :missing_required_field} = DarkZenith.Rpm.Extractor.extract(parsed)
      end
    end

    test "rejects a binary package whose physical arch is src" do
      assert {:error, :invalid_nevra} = synthetic(%{Tags.arch() => {:string, "src"}})
    end

    test "rejects malformed v6 SOURCENEVR values" do
      for nevr <- ["no-version", "a-1.0", "a-x:1.0-1", "-1.0-1"] do
        assert {:error, :malformed_sourcenevr} =
                 synthetic(
                   %{
                     Tags.sourcenevr() => {:string, nevr},
                     Tags.longsize() => {:int64, [10]},
                     Tags.encoding() => {:string, "utf-8"},
                     Tags.payloadsizealt_v6() => {:int64, [5]}
                   },
                   format: 6
                 )
      end
    end
  end
end
