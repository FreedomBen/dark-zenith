defmodule DarkZenith.B2.SigV4 do
  @moduledoc """
  AWS Signature Version 4 for the S3-compatible B2 API (DESIGN.md: Upload
  Intents; RPM File Downloads). Implements presigned query-parameter
  authorization (with optional signed content headers, so a presigned PUT
  authorizes only the declared content type and length) and header
  authorization for server-side calls. Verified against the documented AWS
  SigV4 example vectors.
  """

  @algorithm "AWS4-HMAC-SHA256"
  @unsigned_payload "UNSIGNED-PAYLOAD"

  @doc """
  Builds a presigned URL for `method` at `url`.

  Options: `:access_key_id`, `:secret_access_key`, `:region`, `:ttl`
  (seconds), `:now` (UTC DateTime), optional `:signed_headers`
  (`[{name, value}]` beyond `host`) and `:query` (extra query parameters,
  e.g. `versionId`).
  """
  def presign_url(method, url, opts) do
    uri = URI.parse(url)
    now = Keyword.fetch!(opts, :now)
    {amz_date, datestamp} = format_dates(now)
    scope = "#{datestamp}/#{Keyword.fetch!(opts, :region)}/s3/aws4_request"

    headers = canonicalize_headers([{"host", host_header(uri)} | Keyword.get(opts, :signed_headers, [])])
    signed_header_names = signed_header_names(headers)

    query =
      Keyword.get(opts, :query, []) ++
        [
          {"X-Amz-Algorithm", @algorithm},
          {"X-Amz-Credential", "#{Keyword.fetch!(opts, :access_key_id)}/#{scope}"},
          {"X-Amz-Date", amz_date},
          {"X-Amz-Expires", Integer.to_string(Keyword.fetch!(opts, :ttl))},
          {"X-Amz-SignedHeaders", signed_header_names}
        ]

    canonical_query = canonical_query(query)

    canonical_request =
      Enum.join(
        [
          method,
          canonical_path(uri.path || "/"),
          canonical_query,
          canonical_headers(headers),
          signed_header_names,
          @unsigned_payload
        ],
        "\n"
      )

    signature =
      signature(canonical_request, amz_date, scope, Keyword.fetch!(opts, :secret_access_key), datestamp, Keyword.fetch!(opts, :region))

    base =
      %URI{uri | path: canonical_path(uri.path || "/"), query: nil, fragment: nil}
      |> URI.to_string()

    base <> "?" <> canonical_query <> "&X-Amz-Signature=" <> signature
  end

  @doc """
  Signs a server-side request with header authorization. Returns the full
  header list to send: the given headers plus `host`, `x-amz-date`,
  `x-amz-content-sha256` (the `payload_hash`, which may be
  `UNSIGNED-PAYLOAD`), and `authorization`.
  """
  def sign_headers(method, url, headers, payload_hash, opts) do
    uri = URI.parse(url)
    now = Keyword.fetch!(opts, :now)
    {amz_date, datestamp} = format_dates(now)
    region = Keyword.fetch!(opts, :region)
    scope = "#{datestamp}/#{region}/s3/aws4_request"

    all_headers =
      canonicalize_headers(
        headers ++
          [
            {"host", host_header(uri)},
            {"x-amz-content-sha256", payload_hash},
            {"x-amz-date", amz_date}
          ]
      )

    signed_header_names = signed_header_names(all_headers)

    canonical_request =
      Enum.join(
        [
          method,
          canonical_path(uri.path || "/"),
          canonical_query(decode_query(uri.query)),
          canonical_headers(all_headers),
          signed_header_names,
          payload_hash
        ],
        "\n"
      )

    signature =
      signature(canonical_request, amz_date, scope, Keyword.fetch!(opts, :secret_access_key), datestamp, region)

    authorization =
      "#{@algorithm} Credential=#{Keyword.fetch!(opts, :access_key_id)}/#{scope}," <>
        "SignedHeaders=#{signed_header_names},Signature=#{signature}"

    all_headers ++ [{"authorization", authorization}]
  end

  @doc "The payload-hash value for unsigned payloads."
  def unsigned_payload, do: @unsigned_payload

  @doc "Lowercase hex SHA-256, for signed payload hashes."
  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  ## Canonicalization

  defp format_dates(%DateTime{} = now) do
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    {amz_date, binary_part(amz_date, 0, 8)}
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, URI.default_port(scheme)] do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp canonicalize_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), String.trim(value)} end)
    |> Enum.sort()
  end

  defp signed_header_names(headers) do
    headers |> Enum.map(&elem(&1, 0)) |> Enum.join(";")
  end

  defp canonical_headers(headers) do
    Enum.map_join(headers, "", fn {name, value} -> "#{name}:#{value}\n" end)
  end

  defp canonical_query(params) do
    params
    |> Enum.map(fn {name, value} -> {aws_encode(name), aws_encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp decode_query(nil), do: []
  defp decode_query(query), do: query |> URI.decode_query() |> Map.to_list()

  defp canonical_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &aws_encode/1)
  end

  # RFC 3986 unreserved characters only; everything else percent-encoded
  # with uppercase hex, space as %20.
  defp aws_encode(value) do
    URI.encode(value, fn
      c when c in ?A..?Z or c in ?a..?z or c in ?0..?9 -> true
      c when c in [?-, ?., ?_, ?~] -> true
      _c -> false
    end)
  end

  ## Signature

  defp signature(canonical_request, amz_date, scope, secret, datestamp, region) do
    string_to_sign =
      Enum.join([@algorithm, amz_date, scope, sha256_hex(canonical_request)], "\n")

    ("AWS4" <> secret)
    |> hmac(datestamp)
    |> hmac(region)
    |> hmac("s3")
    |> hmac("aws4_request")
    |> hmac(string_to_sign)
    |> Base.encode16(case: :lower)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
