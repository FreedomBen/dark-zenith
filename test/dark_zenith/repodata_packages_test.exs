defmodule DarkZenith.RepodataPackagesTest do
  @moduledoc """
  Package-entry encoders versus the checked-in `createrepo_c` reference
  (DESIGN.md: Metadata Format). The reference blocks are byte-compared where
  the spec requires parity; the documented deviations (`location`, `time
  file=`, no `<packager>`, null-optionals omitted, `<revision>`) are asserted
  against our own rules.
  """

  use ExUnit.Case, async: true

  import DarkZenith.PackagesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Repodata
  alias DarkZenith.Repodata.{Filelists, Other, Primary}

  defp reference(name) do
    File.read!(Path.expand("../support/fixtures/rpms/createrepo_c/#{name}", __DIR__))
  end

  defp entry_string(encoder, package), do: IO.iodata_to_binary(encoder.entry(package))

  describe "primary.xml entries" do
    setup do
      %{package: package_struct_from_rpm(v4_binary())}
    end

    test "the format block byte-matches the createrepo_c reference", %{package: package} do
      [_, reference_format] =
        String.split(reference("primary.xml"), "<name>dz-fixture</name>", parts: 2)

      [reference_format] =
        Regex.run(~r{  <format>\n.*?  </format>\n}s, reference_format, capture: :first)

      entry = entry_string(Primary, package)
      [our_format] = Regex.run(~r{  <format>\n.*?  </format>\n}s, entry, capture: :first)

      assert our_format == reference_format
    end

    test "scalar elements follow the documented rules", %{package: package} do
      entry = entry_string(Primary, package)

      assert entry =~ ~s(<package type="rpm">\n)
      assert entry =~ "  <name>dz-fixture</name>\n"
      assert entry =~ "  <arch>noarch</arch>\n"
      assert entry =~ ~s(  <version epoch="2" ver="1.2.3" rel="4"/>\n)
      assert entry =~ ~s(  <checksum type="sha256" pkgid="YES">#{package.sha256}</checksum>\n)
      assert entry =~ "  <url>https://example.com/dz-fixture</url>\n"

      # time: file = inserted_at, build = build_time.
      file_unix = DateTime.to_unix(package.inserted_at)
      assert entry =~ ~s(  <time file="#{file_unix}" build="1787200000"/>\n)

      assert entry =~
               ~s(  <size package="#{package.size_package}" installed="48" archive="588"/>\n)

      assert entry =~
               ~s(  <location href="packages/#{package.id}/dz-fixture-1.2.3-4.noarch.rpm"/>\n)

      # The packager element is never emitted.
      refute entry =~ "<packager>"
    end

    test "build falls back to inserted_at when build_time is null", %{package: package} do
      entry = entry_string(Primary, %{package | build_time: nil})
      file_unix = DateTime.to_unix(package.inserted_at)
      assert entry =~ ~s(  <time file="#{file_unix}" build="#{file_unix}"/>\n)
    end

    test "null optionals and empty dependency elements are omitted" do
      package = package_struct_from_rpm(minimal_binary())
      entry = entry_string(Primary, package)

      refute entry =~ "<url>"
      refute entry =~ "rpm:vendor"
      assert entry =~ "<rpm:sourcerpm>dz-minimal-0.1-1.src.rpm</rpm:sourcerpm>"
      refute entry =~ "<rpm:requires>"
      refute entry =~ "<rpm:conflicts>"
      assert entry =~ "<rpm:provides>"
      assert entry =~ ~s(  <version epoch="0" ver="0.1" rel="1"/>\n)
      # archive present for this package; no file entries at all.
      refute entry =~ "<file>"
    end

    test "the archive size attribute is omitted when null", %{package: package} do
      entry = entry_string(Primary, %{package | size_archive: nil})
      assert entry =~ ~s(  <size package="#{package.size_package}" installed="48"/>\n)
    end

    test "only primary files appear, with the filelists type mapping" do
      package =
        package_struct_from_rpm(v4_binary(),
          files: [
            %{"path" => "/usr/bin/tool", "type" => "file", "flags" => []},
            %{"path" => "/etc/tool.conf", "type" => "file", "flags" => ["config"]},
            %{"path" => "/usr/lib/sendmail", "type" => "symlink", "flags" => []},
            %{"path" => "/usr/share/doc/tool", "type" => "file", "flags" => []},
            %{"path" => "/etc/tool.d", "type" => "directory", "flags" => []},
            %{"path" => "/etc/ghosty", "type" => "file", "flags" => ["ghost"]}
          ]
        )

      entry = entry_string(Primary, package)

      assert entry =~ "    <file>/usr/bin/tool</file>\n"
      assert entry =~ "    <file>/etc/tool.conf</file>\n"
      assert entry =~ "    <file>/usr/lib/sendmail</file>\n"
      assert entry =~ ~s(    <file type="dir">/etc/tool.d</file>\n)
      assert entry =~ ~s(    <file type="ghost">/etc/ghosty</file>\n)
      refute entry =~ "/usr/share/doc/tool"
    end

    test "XML-special characters are escaped" do
      package =
        package_struct_from_rpm(minimal_binary(),
          summary: ~s(a <b> & "c"),
          provides: [
            %{
              "name" => "cap<&>",
              "op" => "=",
              "epoch" => 0,
              "version" => ~s(1"2),
              "release" => nil
            }
          ]
        )

      entry = entry_string(Primary, package)
      assert entry =~ "  <summary>a &lt;b&gt; &amp; &quot;c&quot;</summary>\n"

      assert entry =~
               ~s(      <rpm:entry name="cap&lt;&amp;&gt;" flags="EQ" epoch="0" ver="1&quot;2"/>\n)
    end
  end

  describe "filelists.xml entries" do
    test "the fixture package block byte-matches the createrepo_c reference" do
      package = package_struct_from_rpm(v4_binary())

      [reference_block] =
        Regex.run(
          ~r{<package pkgid="#{package.sha256}".*?</package>\n}s,
          reference("filelists.xml")
        )

      assert entry_string(Filelists, package) == reference_block
    end

    test "a package without files emits only the version element" do
      package = package_struct_from_rpm(minimal_binary())

      [reference_block] =
        Regex.run(
          ~r{<package pkgid="#{package.sha256}".*?</package>\n}s,
          reference("filelists.xml")
        )

      assert entry_string(Filelists, package) == reference_block
    end

    test "ghost files carry type ghost unless they are directories" do
      package =
        package_struct_from_rpm(minimal_binary(),
          files: [
            %{"path" => "/a/ghost", "type" => "file", "flags" => ["ghost"]},
            %{"path" => "/a/ghostdir", "type" => "directory", "flags" => ["ghost"]},
            %{"path" => "/a/link", "type" => "symlink", "flags" => []}
          ]
        )

      entry = entry_string(Filelists, package)
      assert entry =~ ~s(  <file type="ghost">/a/ghost</file>\n)
      assert entry =~ ~s(  <file type="dir">/a/ghostdir</file>\n)
      assert entry =~ "  <file>/a/link</file>\n"
    end
  end

  describe "other.xml entries" do
    test "the fixture package block byte-matches the createrepo_c reference" do
      package = package_struct_from_rpm(v4_binary())

      [reference_block] =
        Regex.run(~r{<package pkgid="#{package.sha256}".*?</package>\n}s, reference("other.xml"))

      assert entry_string(Other, package) == reference_block
    end

    test "keeps the first ten header entries, written oldest-first with tie bumps" do
      changelogs =
        for i <- 13..1//-1 do
          %{
            "timestamp" => DateTime.from_unix!(1_000_000 + i * 100) |> DateTime.to_iso8601(),
            "author" => "A - #{i}",
            "text" => "entry #{i}"
          }
        end

      # Give entries 12 and 13 the same timestamp to exercise the bump.
      changelogs =
        List.update_at(changelogs, 0, fn e ->
          %{e | "timestamp" => DateTime.from_unix!(1_000_000 + 12 * 100) |> DateTime.to_iso8601()}
        end)

      package = package_struct_from_rpm(minimal_binary(), changelogs: changelogs)
      entry = entry_string(Other, package)

      dates =
        ~r{date="(\d+)">([^<]*)}
        |> Regex.scan(entry, capture: :all_but_first)
        |> Enum.map(fn [date, text] -> {String.to_integer(date), text} end)

      # First ten header entries are 13..4; emitted oldest-first: 4..13.
      assert Enum.map(dates, &elem(&1, 1)) == Enum.map(4..13, &"entry #{&1}")

      # Strictly increasing dates: the tied 13 is bumped one past 12.
      date_values = Enum.map(dates, &elem(&1, 0))
      assert date_values == Enum.sort(date_values)
      assert length(Enum.uniq(date_values)) == length(date_values)
      assert List.last(date_values) == 1_000_000 + 12 * 100 + 1
    end
  end

  describe "counting-sink accounting" do
    test "per-entry sizes plus document overhead equal the generated open sizes" do
      packages = [
        package_struct_from_rpm(v4_binary()),
        package_struct_from_rpm(minimal_binary())
      ]

      generation = Repodata.generate(packages, revision: 3, timestamp: 1_756_500_000)

      totals =
        Enum.reduce(packages, %{primary: 0, filelists: 0, other: 0}, fn package, acc ->
          sizes = Repodata.entry_open_sizes(package)
          Map.new(acc, fn {key, sum} -> {key, sum + Map.fetch!(sizes, key)} end)
        end)

      overhead = Repodata.document_overhead(length(packages))

      assert generation.open_sizes.primary == totals.primary + overhead.primary
      assert generation.open_sizes.filelists == totals.filelists + overhead.filelists
      assert generation.open_sizes.other == totals.other + overhead.other
    end

    test "overhead accounts for the decimal packages attribute width" do
      assert Repodata.document_overhead(10).primary ==
               Repodata.document_overhead(9).primary + 1
    end
  end
end
