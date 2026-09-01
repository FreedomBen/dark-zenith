defmodule DarkZenith.Rpm.Extractor do
  @moduledoc """
  Semantic metadata extraction and validation over a structurally parsed RPM
  (DESIGN.md: Package Upload & Processing step 3).

  Enforces the NEVRA charset (which deliberately excludes `^`), string
  length/control-character/XML 1.0/UTF-8 rules, i18n C-locale selection,
  parallel-array cardinality, dictionary index ranges, the collection caps
  (65 536 dependencies per list, 262 144 files, 4 096 changelogs),
  createrepo_c-normalized `requires`, and the v4/v6 size and source-reference
  rules.
  """

  import Bitwise

  alias DarkZenith.Rpm.{Header, Metadata, Parser, Tags}

  @nevra_format ~r/^[A-Za-z0-9._+~-]+$/
  @max_epoch 4_294_967_295
  @max_int64 9_223_372_036_854_775_807
  @max_dependencies 65_536
  @max_files 262_144
  @max_changelogs 4_096

  @dep_lists [
    {:requires, 1049, 1048, 1050},
    {:provides, 1047, 1112, 1113},
    {:conflicts, 1054, 1053, 1055},
    {:obsoletes, 1090, 1114, 1115},
    {:recommends, 5046, 5048, 5047},
    {:suggests, 5049, 5051, 5050},
    {:supplements, 5052, 5054, 5053},
    {:enhances, 5055, 5057, 5056}
  ]

  @doc "Extracts a `%Metadata{}` from a `%Parser{}` result."
  def extract(%Parser{} = parsed) do
    header = parsed.header

    with {:ok, i18n_index} <- i18n_index(header),
         {:ok, name} <- required_string(header, Tags.name()),
         {:ok, version} <- required_string(header, Tags.version()),
         {:ok, release} <- required_string(header, Tags.release()),
         {:ok, epoch} <- epoch(header),
         source? = source_package?(header),
         {:ok, arch} <- arch(header, source?),
         :ok <- validate_nevra(name, version, release, arch),
         {:ok, summary} <- required_i18n(header, Tags.summary(), i18n_index),
         {:ok, summary} <- single_line(summary, 256),
         {:ok, description} <- required_i18n(header, Tags.description(), i18n_index),
         {:ok, description} <- multi_line(description, 65_536),
         {:ok, license} <- required_string(header, Tags.license()),
         {:ok, license} <- single_line(license, 256),
         {:ok, url} <- url(header),
         {:ok, rpm_group} <- optional_i18n(header, Tags.group(), i18n_index, 256),
         {:ok, rpm_vendor} <- optional_string(header, Tags.vendor(), 256),
         {:ok, rpm_buildhost} <- optional_string(header, Tags.buildhost(), 256),
         {:ok, size_installed} <- installed_size(parsed),
         {:ok, size_archive} <- archive_size(parsed),
         {:ok, build_time} <- build_time(header),
         {:ok, {rpm_sourcerpm, rpm_sourcenevr}} <- source_refs(parsed, source?),
         {:ok, deps} <- dep_lists(header),
         {:ok, files} <- files(header),
         {:ok, changelogs} <- changelogs(header) do
      {:ok,
       %Metadata{
         rpm_format: parsed.format,
         openpgp_signed?: openpgp_signed?(parsed.signature),
         name: name,
         epoch: epoch,
         version: version,
         release: release,
         arch: arch,
         summary: summary,
         description: description,
         license: license,
         url: url,
         rpm_group: rpm_group,
         rpm_vendor: rpm_vendor,
         rpm_buildhost: rpm_buildhost,
         rpm_sourcerpm: rpm_sourcerpm,
         rpm_sourcenevr: rpm_sourcenevr,
         size_installed: size_installed,
         size_archive: size_archive,
         build_time: build_time,
         source_package?: source?,
         header_start: parsed.header_start,
         header_end: parsed.header_end,
         requires: deps.requires,
         provides: deps.provides,
         conflicts: deps.conflicts,
         obsoletes: deps.obsoletes,
         recommends: deps.recommends,
         suggests: deps.suggests,
         supplements: deps.supplements,
         enhances: deps.enhances,
         files: files,
         changelogs: changelogs
       }}
    end
  end

  # Whether the signature header carries an OpenPGP package signature
  # (selects --resign over --addsign; DESIGN.md: RPM signing step 4).
  defp openpgp_signed?(signature) do
    Enum.any?(Tags.openpgp_signature_tags(), &Header.has?(signature, &1))
  end

  ## Scalar fields

  defp required_string(header, tag) do
    case Header.get(header, tag) do
      {:string, value} -> {:ok, value}
      nil -> {:error, :missing_required_field}
      _other -> {:error, :malformed_header_value}
    end
  end

  defp optional_string(header, tag, max) do
    case Header.get(header, tag) do
      nil -> {:ok, nil}
      {:string, value} -> optional_single_line(value, max)
      _other -> {:error, :malformed_header_value}
    end
  end

  defp epoch(header) do
    case Header.get(header, Tags.epoch()) do
      nil -> {:ok, 0}
      {:int32, [value]} when value <= @max_epoch -> {:ok, value}
      _other -> {:error, :malformed_header_value}
    end
  end

  defp source_package?(header) do
    match?({:int32, [value]} when value != 0, Header.get(header, Tags.sourcepackage()))
  end

  # Source packages store the literal `src` and ignore the physical ARCH tag;
  # binary packages whose physical ARCH is `src` are rejected.
  defp arch(_header, true), do: {:ok, "src"}

  defp arch(header, false) do
    case required_string(header, Tags.arch()) do
      {:ok, "src"} -> {:error, :invalid_nevra}
      other -> other
    end
  end

  defp validate_nevra(name, version, release, arch) do
    valid? =
      Enum.all?([name, version, release, arch], fn value ->
        byte_size(value) > 0 and String.length(value) <= 256 and value =~ @nevra_format
      end)

    if valid?, do: :ok, else: {:error, :invalid_nevra}
  end

  ## i18n strings

  defp i18n_index(header) do
    case Header.get(header, Tags.i18n_table()) do
      nil ->
        {:ok, nil}

      {:string_array, locales} ->
        {:ok, {Enum.find_index(locales, &(&1 == "C")) || 0, length(locales)}}

      # Some builders (rpm-rs, via cargo-generate-rpm) write a single-locale
      # table with the STRING type instead of STRING_ARRAY. It is a one-entry
      # table, and index 0 is both the C match and the first-entry fallback.
      {:string, _locale} ->
        {:ok, {0, 1}}

      _other ->
        {:error, :malformed_header_value}
    end
  end

  defp required_i18n(header, tag, i18n_index) do
    case Header.get(header, tag) do
      nil -> {:error, :missing_required_field}
      value -> select_i18n(value, i18n_index)
    end
  end

  defp optional_i18n(header, tag, i18n_index, max) do
    case Header.get(header, tag) do
      nil ->
        {:ok, nil}

      value ->
        with {:ok, selected} <- select_i18n(value, i18n_index) do
          optional_single_line(selected, max)
        end
    end
  end

  defp select_i18n({:string, value}, _i18n_index), do: {:ok, value}

  defp select_i18n({:i18n_string, values}, nil) do
    case values do
      [only] -> {:ok, only}
      _other -> {:error, :malformed_i18n}
    end
  end

  defp select_i18n({:i18n_string, values}, {index, table_size}) do
    if length(values) == table_size do
      {:ok, Enum.at(values, index)}
    else
      {:error, :malformed_i18n}
    end
  end

  defp select_i18n(_value, _i18n_index), do: {:error, :malformed_header_value}

  ## String content rules

  defp single_line(value, max) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :missing_required_field}
      not valid_xml_string?(value) -> {:error, :invalid_string}
      has_control?(value, []) -> {:error, :invalid_string}
      String.length(value) > max -> {:error, :string_too_long}
      true -> {:ok, value}
    end
  end

  defp optional_single_line(value, max) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        with {:ok, trimmed} <- single_line(trimmed, max), do: {:ok, trimmed}
    end
  end

  defp multi_line(value, max) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :missing_required_field}
      not valid_xml_string?(value) -> {:error, :invalid_string}
      has_control?(value, [?\n, ?\t]) -> {:error, :invalid_string}
      String.length(value) > max -> {:error, :string_too_long}
      true -> {:ok, value}
    end
  end

  # Collection members: valid UTF-8 with only XML 1.0 characters.
  defp collection_string(value) do
    if valid_xml_string?(value), do: {:ok, value}, else: {:error, :invalid_string}
  end

  defp valid_xml_string?(value) do
    String.valid?(value) and Enum.all?(String.to_charlist(value), &xml_char?/1)
  end

  defp xml_char?(c) when c in [0x9, 0xA, 0xD], do: true
  defp xml_char?(c) when c >= 0x20 and c <= 0xD7FF, do: true
  defp xml_char?(c) when c >= 0xE000 and c <= 0xFFFD, do: true
  defp xml_char?(c) when c >= 0x10000 and c <= 0x10FFFF, do: true
  defp xml_char?(_c), do: false

  defp has_control?(value, allowed) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn c -> (c < 0x20 or c == 0x7F) and c not in allowed end)
  end

  ## URL

  defp url(header) do
    case Header.get(header, Tags.url()) do
      nil ->
        {:ok, nil}

      {:string, value} ->
        case String.trim(value) do
          "" ->
            {:ok, nil}

          trimmed ->
            case single_line(trimmed, 256) do
              {:ok, trimmed} ->
                if trimmed =~ ~r{^https?://\S+$} do
                  {:ok, trimmed}
                else
                  {:error, :invalid_url}
                end

              {:error, _} ->
                {:error, :invalid_url}
            end
        end

      _other ->
        {:error, :malformed_header_value}
    end
  end

  ## Sizes and build time

  defp installed_size(%Parser{format: 4, header: header}) do
    case {Header.get(header, Tags.longsize()), Header.get(header, Tags.size())} do
      {{:int64, [value]}, _} -> bounded_size(value)
      {nil, {:int32, [value]}} -> bounded_size(value)
      {nil, nil} -> {:error, :missing_required_field}
      _other -> {:error, :malformed_header_value}
    end
  end

  defp installed_size(%Parser{format: 6, header: header}) do
    case Header.get(header, Tags.longsize()) do
      {:int64, [value]} -> bounded_size(value)
      nil -> {:error, :missing_required_field}
      _other -> {:error, :malformed_header_value}
    end
  end

  defp archive_size(%Parser{format: 4, signature: signature}) do
    case {Header.get(signature, Tags.sig_longarchivesize()),
          Header.get(signature, Tags.sig_payloadsize())} do
      {{:int64, [value]}, _} -> bounded_size(value)
      {nil, {:int32, [value]}} -> bounded_size(value)
      {nil, nil} -> {:ok, nil}
      _other -> {:error, :malformed_header_value}
    end
  end

  defp archive_size(%Parser{format: 6, header: header}) do
    case Header.get(header, Tags.payloadsizealt_v6()) do
      {:int64, [value]} -> bounded_size(value)
      _other -> {:error, :missing_required_field}
    end
  end

  defp bounded_size(value) when value >= 0 and value <= @max_int64, do: {:ok, value}
  defp bounded_size(_value), do: {:error, :malformed_header_value}

  defp build_time(header) do
    case Header.get(header, Tags.buildtime()) do
      nil -> {:ok, nil}
      {:int32, [value]} -> {:ok, DateTime.from_unix!(value)}
      _other -> {:error, :malformed_header_value}
    end
  end

  ## Source references

  defp source_refs(_parsed, true), do: {:ok, {nil, nil}}

  defp source_refs(%Parser{format: 4, header: header}, false) do
    case Header.get(header, Tags.sourcerpm()) do
      nil ->
        {:ok, {nil, nil}}

      {:string, value} ->
        with {:ok, trimmed} <- optional_single_line(value, 800) do
          {:ok, {trimmed, nil}}
        end

      _other ->
        {:error, :malformed_header_value}
    end
  end

  defp source_refs(%Parser{format: 6, header: header}, false) do
    case Header.get(header, Tags.sourcenevr()) do
      nil ->
        {:error, :missing_sourcenevr}

      {:string, value} ->
        with {:ok, nevr} <- single_line_as(value, 800, :malformed_sourcenevr),
             {:ok, sourcerpm} <- derive_sourcerpm(nevr) do
          {:ok, {sourcerpm, nevr}}
        end

      _other ->
        {:error, :malformed_header_value}
    end
  end

  defp single_line_as(value, max, error) do
    case single_line(value, max) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, _} -> {:error, error}
    end
  end

  # SOURCENEVR is name-[epoch:]version-release; the derived filename drops
  # the epoch. A malformed or non-round-trippable value is rejected.
  defp derive_sourcerpm(nevr) do
    with [prefix, release] when prefix != "" and release != "" <- rsplit(nevr, "-"),
         [name, ev] when name != "" and ev != "" <- rsplit(prefix, "-"),
         {:ok, epoch_prefix, version} <- split_evr_epoch(ev),
         true <- version != "",
         true <- "#{name}-#{epoch_prefix}#{version}-#{release}" == nevr do
      sourcerpm = "#{name}-#{version}-#{release}.src.rpm"

      if byte_size(sourcerpm) <= 800 do
        {:ok, sourcerpm}
      else
        {:error, :malformed_sourcenevr}
      end
    else
      _ -> {:error, :malformed_sourcenevr}
    end
  end

  defp rsplit(value, separator) do
    case String.split(value, separator) do
      parts when length(parts) >= 2 ->
        {leading, [last]} = Enum.split(parts, -1)
        [Enum.join(leading, separator), last]

      _other ->
        :nomatch
    end
  end

  defp split_evr_epoch(ev) do
    case String.split(ev, ":", parts: 2) do
      [version] ->
        {:ok, "", version}

      [epoch, version] ->
        if epoch =~ ~r/^\d+$/ and String.to_integer(epoch) <= @max_epoch do
          {:ok, epoch <> ":", version}
        else
          {:error, :malformed_sourcenevr}
        end
    end
  end

  ## Dependency lists

  defp dep_lists(header) do
    Enum.reduce_while(@dep_lists, {:ok, %{}}, fn {kind, name_tag, flags_tag, version_tag},
                                                 {:ok, acc} ->
      case dep_list(header, kind, name_tag, flags_tag, version_tag) do
        {:ok, entries} -> {:cont, {:ok, Map.put(acc, kind, entries)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp dep_list(header, kind, name_tag, flags_tag, version_tag) do
    case {Header.get(header, name_tag), Header.get(header, flags_tag),
          Header.get(header, version_tag)} do
      {nil, nil, nil} ->
        {:ok, []}

      {{:string_array, names}, {:int32, flags}, {:string_array, versions}} ->
        cond do
          length(names) > @max_dependencies ->
            {:error, :too_many_dependencies}

          length(names) != length(flags) or length(names) != length(versions) ->
            {:error, :malformed_dependency}

          true ->
            build_dep_entries(kind, names, flags, versions)
        end

      _other ->
        {:error, :malformed_dependency}
    end
  end

  defp build_dep_entries(kind, names, flags, versions) do
    [names, flags, versions]
    |> Enum.zip()
    |> Enum.reduce_while({:ok, []}, fn {name, flag, version}, {:ok, acc} ->
      cond do
        kind == :requires and rpmlib_entry?(name, flag) ->
          {:cont, {:ok, acc}}

        true ->
          case dep_entry(kind, name, flag, version) do
            {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, reversed} ->
        entries = Enum.reverse(reversed)
        {:ok, if(kind == :requires, do: collapse_duplicates(entries), else: entries)}

      error ->
        error
    end
  end

  defp rpmlib_entry?(name, flag) do
    (flag &&& Tags.rpmsense_rpmlib()) != 0 or String.starts_with?(name, "rpmlib(")
  end

  defp dep_entry(kind, name, flag, version) do
    with {:ok, name} <- collection_string(name),
         {:ok, _} <- collection_string(version),
         {:ok, op} <- dep_op(flag),
         {:ok, versioned} <- dep_version(name, op, version) do
      base = %{
        "name" => name,
        "op" => op,
        "epoch" => versioned[:epoch],
        "version" => versioned[:version],
        "release" => versioned[:release]
      }

      entry =
        if kind == :requires do
          Map.put(base, "pre", (flag &&& Tags.rpmsense_pre_mask()) != 0)
        else
          base
        end

      {:ok, entry}
    end
  end

  defp dep_op(flag) do
    case flag &&& Tags.rpmsense_comparison_mask() do
      0 -> {:ok, nil}
      2 -> {:ok, "<"}
      4 -> {:ok, ">"}
      8 -> {:ok, "="}
      10 -> {:ok, "<="}
      12 -> {:ok, ">="}
      _other -> {:error, :malformed_dependency}
    end
  end

  # Rich (boolean) dependencies are unversioned by definition; versioned
  # entries require both the operator and a version, and vice versa.
  defp dep_version(name, op, version) do
    rich? = String.starts_with?(name, "(")

    cond do
      rich? and (op != nil or version != "") -> {:error, :malformed_dependency}
      op == nil and version != "" -> {:error, :malformed_dependency}
      op != nil and version == "" -> {:error, :malformed_dependency}
      op == nil -> {:ok, %{epoch: nil, version: nil, release: nil}}
      true -> parse_dep_evr(version)
    end
  end

  defp parse_dep_evr(evr) do
    {epoch, rest} =
      case String.split(evr, ":", parts: 2) do
        [rest] -> {"0", rest}
        [epoch, rest] -> {epoch, rest}
      end

    {version, release} =
      case String.split(rest, "-", parts: 2) do
        [version] -> {version, nil}
        [version, release] -> {version, release}
      end

    valid? =
      epoch =~ ~r/^\d+$/ and String.to_integer(epoch) <= @max_epoch and version != "" and
        release != ""

    if valid? do
      {:ok, %{epoch: String.to_integer(epoch), version: version, release: release}}
    else
      {:error, :malformed_dependency}
    end
  end

  defp collapse_duplicates(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      if MapSet.member?(seen, entry) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, entry)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  ## Files

  defp files(header) do
    values =
      {Header.get(header, Tags.dirindexes()), Header.get(header, Tags.basenames()),
       Header.get(header, Tags.dirnames()), Header.get(header, Tags.filemodes()),
       Header.get(header, Tags.fileflags())}

    case values do
      {nil, nil, nil, _modes, _flags} ->
        if Header.has?(header, Tags.old_filenames()) do
          {:error, :malformed_files}
        else
          {:ok, []}
        end

      {{:int32, dirindexes}, {:string_array, basenames}, {:string_array, dirnames},
       {:int16, modes}, {:int32, flags}} ->
        count = length(basenames)

        cond do
          count > @max_files ->
            {:error, :too_many_files}

          length(dirindexes) != count or length(modes) != count or length(flags) != count ->
            {:error, :malformed_files}

          Enum.any?(dirindexes, &(&1 >= length(dirnames))) ->
            {:error, :malformed_files}

          true ->
            build_file_entries(dirindexes, basenames, dirnames, modes, flags)
        end

      _other ->
        {:error, :malformed_files}
    end
  end

  defp build_file_entries(dirindexes, basenames, dirnames, modes, flags) do
    dirs = List.to_tuple(dirnames)

    [dirindexes, basenames, modes, flags]
    |> Enum.zip()
    |> Enum.reduce_while({:ok, []}, fn {dirindex, basename, mode, flag}, {:ok, acc} ->
      path = elem(dirs, dirindex) <> basename

      case collection_string(path) do
        {:ok, path} ->
          entry = %{"path" => path, "type" => file_type(mode), "flags" => file_flags(flag)}
          {:cont, {:ok, [entry | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp file_type(mode) do
    case mode &&& 0xF000 do
      0o040000 -> "directory"
      0o120000 -> "symlink"
      _other -> "file"
    end
  end

  defp file_flags(flag) do
    for {name, bit} <- [
          {"config", Tags.rpmfile_config()},
          {"doc", Tags.rpmfile_doc()},
          {"ghost", Tags.rpmfile_ghost()},
          {"license", Tags.rpmfile_license()},
          {"readme", Tags.rpmfile_readme()}
        ],
        (flag &&& bit) != 0,
        do: name
  end

  ## Changelogs

  defp changelogs(header) do
    values =
      {Header.get(header, Tags.changelogtime()), Header.get(header, Tags.changelogname()),
       Header.get(header, Tags.changelogtext())}

    case values do
      {nil, nil, nil} ->
        {:ok, []}

      {{:int32, times}, {:string_array, names}, {:string_array, texts}} ->
        count = length(times)

        cond do
          count > @max_changelogs ->
            {:error, :too_many_changelogs}

          length(names) != count or length(texts) != count ->
            {:error, :malformed_changelogs}

          true ->
            build_changelog_entries(times, names, texts)
        end

      _other ->
        {:error, :malformed_changelogs}
    end
  end

  defp build_changelog_entries(times, names, texts) do
    [times, names, texts]
    |> Enum.zip()
    |> Enum.reduce_while({:ok, []}, fn {time, name, text}, {:ok, acc} ->
      with {:ok, name} <- changelog_string(name),
           {:ok, text} <- changelog_string(text) do
        entry = %{
          "timestamp" => time |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          "author" => name,
          "text" => text
        }

        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Changelog text may contain newlines and tabs but no other control
  # characters, like the description.
  defp changelog_string(value) do
    cond do
      not valid_xml_string?(value) -> {:error, :invalid_string}
      has_control?(value, [?\n, ?\t]) -> {:error, :invalid_string}
      true -> {:ok, value}
    end
  end
end
