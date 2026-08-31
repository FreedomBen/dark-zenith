defmodule DarkZenith.Rpm.Header do
  @moduledoc """
  One RPM header section — the tag index plus data store shared by the
  signature and main headers (DESIGN.md: RPM Parsing).

  `parse/3` enforces the structural invariants that apply to every header:
  known entry types and positive counts, unique tags, aligned in-bounds
  non-overlapping data references, and a leading region entry with a valid
  trailer. Format-specific rules (v6 sorted tags and zero padding) are
  checked by the caller against the parsed structure.
  """

  defstruct [:entries, :values, :data, :start, :byte_size]

  @magic <<0x8E, 0xAD, 0xE8, 0x01>>
  @max_entries 65_535

  @type_null 0
  @type_char 1
  @type_int8 2
  @type_int16 3
  @type_int32 4
  @type_int64 5
  @type_string 6
  @type_bin 7
  @type_string_array 8
  @type_i18n_string 9

  @doc """
  Reads `{:ok, nindex, hsize}` from the 16-byte header prefix at `offset`
  without touching the body, for bounds enforcement before parsing.
  """
  def peek(binary, offset) do
    case slice(binary, offset, 16) do
      <<@magic, _reserved::binary-4, nindex::32, hsize::32>> ->
        cond do
          nindex > @max_entries -> {:error, :too_many_entries}
          nindex < 1 -> {:error, :empty_header}
          true -> {:ok, nindex, hsize}
        end

      nil -> {:error, :truncated}
      _ -> {:error, :bad_header_magic}
    end
  end

  @doc "Total byte size of a header with the given index/data sizes."
  def total_size(nindex, hsize), do: 16 + nindex * 16 + hsize

  @doc """
  Parses the header at `offset`. `region_tag` is the expected leading region
  entry (62 for the signature header, 63 for the main header).

  Returns `{:ok, header}` or `{:error, reason}`.
  """
  def parse(binary, offset, region_tag) do
    with {:ok, nindex, hsize} <- peek(binary, offset),
         index_bytes when not is_nil(index_bytes) <- slice(binary, offset + 16, nindex * 16),
         data when not is_nil(data) <- slice(binary, offset + 16 + nindex * 16, hsize),
         {:ok, entries} <- parse_entries(index_bytes, data, hsize),
         :ok <- check_unique_tags(entries),
         :ok <- check_region(entries, data, region_tag, nindex),
         :ok <- check_overlaps(entries),
         {:ok, values} <- decode_values(entries, data) do
      {:ok,
       %__MODULE__{
         entries: entries,
         values: values,
         data: data,
         start: offset,
         byte_size: total_size(nindex, hsize)
       }}
    else
      nil -> {:error, :truncated}
      {:error, _} = error -> error
    end
  end

  @doc "The decoded `{type, value}` for a tag, or nil."
  def get(%__MODULE__{values: values}, tag), do: Map.get(values, tag)

  @doc "True when the header physically carries the tag."
  def has?(%__MODULE__{values: values}, tag), do: Map.has_key?(values, tag)

  @doc "Physical tag numbers in entry order."
  def tags(%__MODULE__{entries: entries}), do: Enum.map(entries, &elem(&1, 0))

  @doc "True when tags are strictly increasing (v6 requirement)."
  def sorted?(%__MODULE__{} = header) do
    header |> tags() |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)
  end

  @doc """
  True when every data-store byte not covered by an entry is zero
  (v6 zero-filled padding requirement).
  """
  def padding_zero?(%__MODULE__{entries: entries, data: data}) do
    covered =
      entries
      |> Enum.map(fn {_tag, _type, offset, _count, size} -> {offset, size} end)
      |> Enum.filter(fn {_offset, size} -> size > 0 end)
      |> Enum.sort()

    gaps_zero?(covered, 0, data)
  end

  defp gaps_zero?([], position, data) do
    zero_bytes?(binary_part(data, position, byte_size(data) - position))
  end

  defp gaps_zero?([{offset, size} | rest], position, data) when offset >= position do
    if zero_bytes?(binary_part(data, position, offset - position)) do
      gaps_zero?(rest, offset + size, data)
    else
      false
    end
  end

  defp zero_bytes?(binary), do: binary == :binary.copy(<<0>>, byte_size(binary))

  ## Entry parsing

  defp parse_entries(index_bytes, data, hsize) do
    entries =
      for <<tag::signed-32, type::32, offset::32, count::32 <- index_bytes>> do
        {tag, type, offset, count}
      end

    Enum.reduce_while(entries, {:ok, []}, fn {tag, type, offset, count}, {:ok, acc} ->
      case entry_size(type, offset, count, data, hsize) do
        {:ok, size} -> {:cont, {:ok, [{tag, type, offset, count, size} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Computes the byte size of one entry's data, validating type, count,
  # alignment, and bounds.
  defp entry_size(type, offset, count, data, hsize) do
    cond do
      type > @type_i18n_string -> {:error, :unknown_entry_type}
      count < 1 -> {:error, :invalid_count}
      offset > hsize -> {:error, :entry_out_of_bounds}
      rem(offset, alignment(type)) != 0 -> {:error, :misaligned_entry}
      true -> sized(type, offset, count, data, hsize)
    end
  end

  defp sized(type, offset, count, data, hsize) do
    case type do
      @type_null ->
        {:ok, 0}

      @type_string when count != 1 ->
        {:error, :invalid_count}

      t when t in [@type_string, @type_string_array, @type_i18n_string] ->
        string_span(data, offset, if(t == @type_string, do: 1, else: count))

      t ->
        fixed = fixed_size(t) * count

        if offset + fixed <= hsize do
          {:ok, fixed}
        else
          {:error, :entry_out_of_bounds}
        end
    end
  end

  defp fixed_size(@type_char), do: 1
  defp fixed_size(@type_int8), do: 1
  defp fixed_size(@type_int16), do: 2
  defp fixed_size(@type_int32), do: 4
  defp fixed_size(@type_int64), do: 8
  defp fixed_size(@type_bin), do: 1

  defp alignment(@type_int16), do: 2
  defp alignment(@type_int32), do: 4
  defp alignment(@type_int64), do: 8
  defp alignment(_type), do: 1

  # Byte length of `count` consecutive NUL-terminated strings at offset,
  # NULs included.
  defp string_span(data, offset, count) do
    string_span(data, offset, count, 0)
  end

  defp string_span(_data, _offset, 0, acc), do: {:ok, acc}

  defp string_span(data, offset, remaining, acc) do
    scope = binary_part(data, offset + acc, byte_size(data) - offset - acc)

    case :binary.match(scope, <<0>>) do
      {nul, 1} -> string_span(data, offset, remaining - 1, acc + nul + 1)
      :nomatch -> {:error, :entry_out_of_bounds}
    end
  rescue
    ArgumentError -> {:error, :entry_out_of_bounds}
  end

  ## Invariants

  defp check_unique_tags(entries) do
    tags = Enum.map(entries, &elem(&1, 0))
    if length(tags) == length(Enum.uniq(tags)), do: :ok, else: {:error, :duplicate_tag}
  end

  defp check_region([{tag, type, offset, count, _size} | _rest], data, region_tag, nindex) do
    cond do
      tag != region_tag ->
        {:error, :missing_region}

      type != @type_bin or count != 16 ->
        {:error, :invalid_region}

      true ->
        <<trailer_tag::signed-32, trailer_type::32, trailer_offset::signed-32,
          trailer_count::32>> = binary_part(data, offset, 16)

        if trailer_tag == region_tag and trailer_type == @type_bin and trailer_count == 16 and
             trailer_offset < 0 and rem(-trailer_offset, 16) == 0 and
             -trailer_offset <= nindex * 16 do
          :ok
        else
          {:error, :invalid_region}
        end
    end
  end

  defp check_overlaps(entries) do
    ranges =
      entries
      |> Enum.map(fn {_tag, _type, offset, _count, size} -> {offset, size} end)
      |> Enum.filter(fn {_offset, size} -> size > 0 end)
      |> Enum.sort()

    overlap? =
      ranges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{o1, s1}, {o2, _s2}] -> o1 + s1 > o2 end)

    if overlap?, do: {:error, :overlapping_entries}, else: :ok
  end

  ## Decoding

  defp decode_values(entries, data) do
    values =
      Map.new(entries, fn {tag, type, offset, count, size} ->
        {tag, {type_atom(type), decode(type, offset, count, size, data)}}
      end)

    {:ok, values}
  end

  defp type_atom(@type_null), do: :null
  defp type_atom(@type_char), do: :char
  defp type_atom(@type_int8), do: :int8
  defp type_atom(@type_int16), do: :int16
  defp type_atom(@type_int32), do: :int32
  defp type_atom(@type_int64), do: :int64
  defp type_atom(@type_string), do: :string
  defp type_atom(@type_bin), do: :bin
  defp type_atom(@type_string_array), do: :string_array
  defp type_atom(@type_i18n_string), do: :i18n_string

  defp decode(@type_null, _offset, _count, _size, _data), do: nil

  defp decode(type, offset, count, size, data) when type in [@type_char, @type_bin] do
    _ = count
    binary_part(data, offset, size)
  end

  defp decode(@type_int8, offset, count, _size, data) do
    for <<value::8 <- binary_part(data, offset, count)>>, do: value
  end

  defp decode(@type_int16, offset, count, _size, data) do
    for <<value::16 <- binary_part(data, offset, count * 2)>>, do: value
  end

  defp decode(@type_int32, offset, count, _size, data) do
    for <<value::32 <- binary_part(data, offset, count * 4)>>, do: value
  end

  defp decode(@type_int64, offset, count, _size, data) do
    for <<value::64 <- binary_part(data, offset, count * 8)>>, do: value
  end

  defp decode(@type_string, offset, _count, size, data) do
    binary_part(data, offset, size - 1)
  end

  defp decode(type, offset, count, size, data)
       when type in [@type_string_array, @type_i18n_string] do
    data
    |> binary_part(offset, size)
    |> :binary.split(<<0>>, [:global])
    |> Enum.take(count)
  end

  defp slice(binary, offset, length) do
    if byte_size(binary) >= offset + length do
      binary_part(binary, offset, length)
    else
      nil
    end
  end
end
