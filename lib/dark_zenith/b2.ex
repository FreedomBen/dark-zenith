defmodule DarkZenith.B2 do
  @moduledoc """
  Backblaze B2 S3-compatible client (DESIGN.md: Storage; Upload Intents;
  Package Upload & Processing step 9).

  Path-style addressing against `B2_ENDPOINT`. Presigned URLs carry SigV4
  query authorization; a staging upload URL additionally signs the exact
  content type and declared content length. Server-side calls disable HTTP
  client retries — non-idempotent writes must not be replayed by the
  transport layer; Background Retry Policy owns retries — and every
  infrastructure failure maps to `:storage_unavailable`. Version-aware
  deletion treats an already-absent version as success.
  """

  alias DarkZenith.B2.SigV4

  @content_type "application/x-rpm"
  @forbidden_header_names ~w(content-encoding content-disposition content-language cache-control expires x-amz-website-redirect-location)

  defmodule Config do
    @moduledoc "B2 connection settings (see the Configuration table)."
    @enforce_keys [:key_id, :application_key, :bucket, :endpoint, :region]
    defstruct [:key_id, :application_key, :bucket, :endpoint, :region, req_options: []]
  end

  @doc "Builds the configured `%Config{}` from the application environment."
  def config! do
    settings = Application.get_env(:dark_zenith, :b2) || raise "B2 storage is not configured"
    struct!(Config, settings)
  end

  ## Presigned URLs

  @doc """
  Presigned `PutObject` URL for one staging key, authorizing only the fixed
  content type and the declared content length.
  """
  def staging_upload_url(%Config{} = config, key, content_length, opts) do
    SigV4.presign_url("PUT", object_url(config, key),
      signed_headers: [
        {"content-length", Integer.to_string(content_length)},
        {"content-type", @content_type}
      ],
      ttl: Keyword.fetch!(opts, :ttl),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      access_key_id: config.key_id,
      secret_access_key: config.application_key,
      region: config.region
    )
  end

  @doc "Presigned `GetObject` URL for an exact object version."
  def signed_get_url(%Config{} = config, key, version_id, opts) do
    presigned_version_url(config, "GET", key, version_id, opts)
  end

  @doc """
  Presigned `HeadObject` URL for an exact object version. The HTTP method is
  part of the SigV4 signature, so a `GET` URL is never reused for `HEAD`.
  """
  def signed_head_url(%Config{} = config, key, version_id, opts) do
    presigned_version_url(config, "HEAD", key, version_id, opts)
  end

  defp presigned_version_url(config, method, key, version_id, opts) do
    SigV4.presign_url(method, object_url(config, key),
      query: [{"versionId", version_id}],
      ttl: Keyword.fetch!(opts, :ttl),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      access_key_id: config.key_id,
      secret_access_key: config.application_key,
      region: config.region
    )
  end

  ## Server-side operations

  @doc "Describes one exact object version."
  def head_object(%Config{} = config, key, version_id) do
    case request(config, :head, key, query: [{"versionId", version_id}]) do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, describe(response)}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      _other -> {:error, :storage_unavailable}
    end
  end

  @doc """
  Checks a `head_object/3` result against the staging/final object contract:
  exact length, exact `application/x-rpm` content type, none of the
  forbidden content headers, and an empty user-metadata map (DESIGN.md:
  Upload Intents).
  """
  def verify_object_contract(head, expected_length) do
    cond do
      head.content_length != expected_length -> {:error, :length_mismatch}
      head.content_type != @content_type -> {:error, :content_type_mismatch}
      head.forbidden_headers != %{} -> {:error, :forbidden_headers}
      head.user_metadata != %{} -> {:error, :forbidden_metadata}
      true -> :ok
    end
  end

  @doc """
  Writes a new object version with only the RPM content type. Returns
  `{:ok, version_id}`; a success response without a version id is treated
  as an infrastructure failure, since every stored object must be
  addressable by exact version.
  """
  def put_object(%Config{} = config, key, body) do
    case request(config, :put, key, body: body, headers: [{"content-type", @content_type}]) do
      {:ok, %Req.Response{status: 200} = response} ->
        case version_id(response) do
          nil -> {:error, :storage_unavailable}
          version -> {:ok, version}
        end

      _other ->
        {:error, :storage_unavailable}
    end
  end

  @doc """
  Server-side copy of one exact source version to `dest_key` with
  `MetadataDirective=REPLACE` and only the RPM content type. S3-compatible
  services can return HTTP 200 with an embedded error document, so the body
  must contain a `CopyObjectResult`.
  """
  def copy_object(%Config{} = config, dest_key, source_key, source_version_id) do
    headers = [
      {"x-amz-copy-source", "/#{config.bucket}/#{source_key}?versionId=#{source_version_id}"},
      {"x-amz-metadata-directive", "REPLACE"},
      {"content-type", @content_type}
    ]

    case request(config, :put, dest_key, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        with true <- is_binary(body) and body =~ "CopyObjectResult",
             version when not is_nil(version) <- version_id(response) do
          {:ok, version}
        else
          _ -> {:error, :storage_unavailable}
        end

      _other ->
        {:error, :storage_unavailable}
    end
  end

  @doc """
  Permanently deletes one exact object version (never by key alone, which
  would create a delete marker). An already-absent version is success.
  """
  def delete_version(%Config{} = config, key, version_id) do
    case request(config, :delete, key, query: [{"versionId", version_id}]) do
      {:ok, %Req.Response{status: status}} when status in [200, 204, 404] -> :ok
      _other -> {:error, :storage_unavailable}
    end
  end

  @doc """
  Lists every object version and delete marker under a prefix, following
  `ListObjectVersions` pagination. Entries are
  `%{key:, version_id:, delete_marker?:}`.
  """
  def list_all_object_versions(%Config{} = config, prefix) do
    list_pages(config, prefix, nil, nil, [])
  end

  defp list_pages(config, prefix, key_marker, version_id_marker, acc) do
    query =
      [{"versions", ""}, {"prefix", prefix}] ++
        if(key_marker, do: [{"key-marker", key_marker}], else: []) ++
        if version_id_marker, do: [{"version-id-marker", version_id_marker}], else: []

    case request(config, :get, nil, query: query) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        page = parse_list_versions(body)
        acc = acc ++ page.entries

        if page.truncated? do
          list_pages(config, prefix, page.next_key_marker, page.next_version_id_marker, acc)
        else
          {:ok, acc}
        end

      _other ->
        {:error, :storage_unavailable}
    end
  end

  ## Request plumbing

  defp request(config, method, key, opts) do
    query = Keyword.get(opts, :query, [])
    url = object_url(config, key) <> query_string(query)
    body = Keyword.get(opts, :body)
    payload_hash = SigV4.unsigned_payload()

    headers =
      SigV4.sign_headers(
        method |> to_string() |> String.upcase(),
        url,
        Keyword.get(opts, :headers, []),
        payload_hash,
        access_key_id: config.key_id,
        secret_access_key: config.application_key,
        region: config.region,
        now: DateTime.utc_now()
      )

    [
      method: method,
      url: url,
      headers: headers,
      body: body,
      # Transport-level retries stay off: non-idempotent writes must not be
      # replayed, and Background Retry Policy owns retry scheduling.
      retry: false,
      decode_body: false
    ]
    |> Keyword.merge(config.req_options)
    |> Req.request()
  end

  defp object_url(config, nil), do: "#{config.endpoint}/#{config.bucket}"
  defp object_url(config, key), do: "#{config.endpoint}/#{config.bucket}/#{key}"

  defp query_string([]), do: ""

  defp query_string(params) do
    "?" <>
      Enum.map_join(params, "&", fn {name, value} ->
        URI.encode_www_form(name) <> "=" <> URI.encode_www_form(value)
      end)
  end

  defp describe(%Req.Response{} = response) do
    %{
      content_length: response |> header("content-length") |> parse_length(),
      content_type: header(response, "content-type"),
      version_id: version_id(response),
      forbidden_headers:
        for name <- @forbidden_header_names,
            value = header(response, name),
            into: %{} do
          {name, value}
        end,
      user_metadata:
        for {name, values} <- response.headers,
            String.starts_with?(name, "x-amz-meta-"),
            into: %{} do
          {name, List.first(values, "")}
        end
    }
  end

  defp parse_length(nil), do: nil
  defp parse_length(value), do: String.to_integer(value)

  defp version_id(response), do: header(response, "x-amz-version-id")

  defp header(%Req.Response{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  ## ListObjectVersions XML

  defp parse_list_versions(xml) do
    {doc, _rest} = xml |> String.to_charlist() |> :xmerl_scan.string(quiet: true)

    versions = collect_entries(doc, ~c"//Version", false)
    markers = collect_entries(doc, ~c"//DeleteMarker", true)

    %{
      entries: versions ++ markers,
      truncated?: text(doc, ~c"//IsTruncated") == "true",
      next_key_marker: presence(text(doc, ~c"//NextKeyMarker")),
      next_version_id_marker: presence(text(doc, ~c"//NextVersionIdMarker"))
    }
  end

  defp collect_entries(doc, path, delete_marker?) do
    for element <- :xmerl_xpath.string(path, doc) do
      %{
        key: text(element, ~c"./Key"),
        version_id: text(element, ~c"./VersionId"),
        delete_marker?: delete_marker?
      }
    end
  end

  defp text(element, path) do
    path
    |> Kernel.++(~c"/text()")
    |> :xmerl_xpath.string(element)
    |> Enum.map_join("", fn text -> text |> elem(4) |> List.to_string() end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
