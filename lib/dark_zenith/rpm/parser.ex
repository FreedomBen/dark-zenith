defmodule DarkZenith.Rpm.Parser do
  @moduledoc """
  Structural parser for RPM v4/v6 packages (DESIGN.md: RPM Parsing; Package
  Upload & Processing step 1).

  Reads the lead, signature header, and main header — never the payload —
  and enforces the structural bounds and format acceptance rules: the
  64 MiB combined-header cap and 65 535-entry cap before parsing, unique
  in-bounds aligned non-overlapping entries, region structure (a main
  header without the immutable region is a v3 shape and is rejected), the
  v4 strong-digest requirements, and the v6 sorted/zero-padded mandatory-tag
  rules. v3 and unknown formats are rejected.
  """

  alias DarkZenith.Rpm.Header
  alias DarkZenith.Rpm.Tags

  defstruct [:format, :signature, :header, :header_start, :header_end, :file_size]

  @lead_size 96
  @lead_magic <<0xED, 0xAB, 0xEE, 0xDB>>
  @max_combined_header_bytes 67_108_864
  @sha256_hex ~r/^[0-9a-f]{64}$/

  @doc "Parses and classifies a complete RPM file binary."
  def parse(binary) when is_binary(binary) do
    with :ok <- check_lead(binary),
         {:ok, sig_nindex, sig_hsize} <- Header.peek(binary, @lead_size),
         :ok <- check_cap(Header.total_size(sig_nindex, sig_hsize)),
         {:ok, signature} <- Header.parse(binary, @lead_size, Tags.region_signature()),
         header_start = main_header_start(signature),
         {:ok, main_nindex, main_hsize} <- Header.peek(binary, header_start),
         :ok <- check_cap(signature.byte_size + Header.total_size(main_nindex, main_hsize)),
         {:ok, header} <- Header.parse(binary, header_start, Tags.region_immutable()),
         {:ok, format} <- classify(header),
         :ok <- check_format(format, binary, signature, header) do
      {:ok,
       %__MODULE__{
         format: format,
         signature: signature,
         header: header,
         header_start: header_start,
         header_end: header_start + header.byte_size,
         file_size: byte_size(binary)
       }}
    end
  end

  defp check_lead(binary) when byte_size(binary) < @lead_size, do: {:error, :truncated}
  defp check_lead(<<@lead_magic, _::binary>>), do: :ok
  defp check_lead(_binary), do: {:error, :bad_lead_magic}

  defp check_cap(bytes) when bytes > @max_combined_header_bytes, do: {:error, :header_too_large}
  defp check_cap(_bytes), do: :ok

  # The signature header data store is padded to an 8-byte boundary before
  # the main header begins.
  defp main_header_start(%Header{start: start, byte_size: byte_size}) do
    sig_end = start + byte_size
    sig_end + rem(8 - rem(sig_end, 8), 8)
  end

  defp classify(header) do
    case Header.get(header, Tags.rpmformat()) do
      nil -> {:ok, 4}
      {:int32, [4]} -> {:ok, 4}
      {:int32, [6]} -> {:ok, 6}
      _other -> {:error, :unsupported_format}
    end
  end

  ## v4 acceptance

  defp check_format(4, _binary, signature, header) do
    with :ok <- require_sha256_string(signature, Tags.sig_sha256()),
         :ok <- check_v4_payload_digest(header) do
      :ok
    end
  end

  ## v6 acceptance

  defp check_format(6, binary, signature, header) do
    with :ok <- check_v6_sorted(signature),
         :ok <- check_v6_sorted(header),
         :ok <- check_v6_signature_tags(signature),
         :ok <- require_sha256_string(signature, Tags.sig_sha256(), :v6_signature_missing_digest),
         :ok <-
           require_sha256_string(signature, Tags.sig_sha3_256(), :v6_signature_missing_digest),
         :ok <- check_v6_reserved(signature),
         :ok <- check_v6_mandatory(header),
         :ok <- check_v6_encoding(header),
         :ok <- check_v6_file_digest_algo(header),
         :ok <- check_v6_zero_padding(binary, signature, header) do
      :ok
    end
  end

  defp require_sha256_string(header, tag, error \\ :weak_digests) do
    case Header.get(header, tag) do
      {:string, value} -> if value =~ @sha256_hex, do: :ok, else: {:error, error}
      _ -> {:error, error}
    end
  end

  # RPM 4.14+ strong payload coverage: PAYLOADDIGEST with SHA-256 algorithm.
  defp check_v4_payload_digest(header) do
    with {:string_array, [digest | _]} <- Header.get(header, Tags.payloaddigest()),
         true <- digest =~ @sha256_hex,
         {:int32, [algo]} <- Header.get(header, Tags.payloaddigestalgo()),
         true <- algo == Tags.pgphashalgo_sha256() do
      :ok
    else
      _ -> {:error, :weak_digests}
    end
  end

  defp check_v6_sorted(header) do
    if Header.sorted?(header), do: :ok, else: {:error, :unsorted_tags}
  end

  # v6 signatures carry no size/payload entries and nothing above tag 999.
  defp check_v6_signature_tags(signature) do
    tags = Header.tags(signature)
    forbidden = [Tags.sig_longsize(), Tags.sig_longarchivesize()]

    if Enum.any?(tags, &(&1 > 999)) or Enum.any?(forbidden, &(&1 in tags)) do
      {:error, :v6_signature_forbidden_tag}
    else
      :ok
    end
  end

  defp check_v6_reserved(signature) do
    case Header.get(signature, Tags.sig_reserved_v6()) do
      {:bin, value} ->
        if value == :binary.copy(<<0>>, byte_size(value)) do
          :ok
        else
          {:error, :v6_reserved_not_zero}
        end

      _ ->
        {:error, :v6_signature_missing_reserved}
    end
  end

  defp check_v6_mandatory(header) do
    mandatory = [
      Tags.longsize(),
      Tags.encoding(),
      Tags.payloaddigest(),
      Tags.payloaddigestalt(),
      Tags.payloadsize_v6(),
      Tags.payloadsizealt_v6()
    ]

    if Enum.all?(mandatory, &Header.has?(header, &1)) do
      :ok
    else
      {:error, :v6_missing_mandatory_tag}
    end
  end

  defp check_v6_encoding(header) do
    case Header.get(header, Tags.encoding()) do
      {:string, "utf-8"} -> :ok
      _ -> {:error, :v6_bad_encoding}
    end
  end

  # When the package carries files, its file-digest algorithm must be at
  # least SHA-256.
  defp check_v6_file_digest_algo(header) do
    if Header.has?(header, Tags.basenames()) do
      case Header.get(header, Tags.filedigestalgo()) do
        {:int32, [algo]} ->
          if algo in Tags.strong_digest_algos(), do: :ok, else: {:error, :v6_weak_file_digest}

        _ ->
          {:error, :v6_weak_file_digest}
      end
    else
      :ok
    end
  end

  defp check_v6_zero_padding(binary, signature, header) do
    sig_end = signature.start + signature.byte_size
    pad = binary_part(binary, sig_end, header.start - sig_end)

    cond do
      pad != :binary.copy(<<0>>, byte_size(pad)) -> {:error, :nonzero_padding}
      not Header.padding_zero?(signature) -> {:error, :nonzero_padding}
      not Header.padding_zero?(header) -> {:error, :nonzero_padding}
      true -> :ok
    end
  end
end
