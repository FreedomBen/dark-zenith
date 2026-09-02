defmodule DarkZenith.FakeBucket do
  @moduledoc """
  An in-memory, versioned stand-in for the B2 bucket behind the
  `DarkZenith.B2Stub` Req.Test plug, for end-to-end tests that need object
  storage to behave like storage rather than return canned responses: the
  bytes a client PUTs through a presigned URL are what the pipeline's later
  HeadObject, GetObject, CopyObject, and cleanup calls see.

  Supports exactly the S3 calls the application makes: presigned or
  header-signed PutObject, CopyObject with `x-amz-copy-source`,
  exact-version HeadObject/GetObject/DeleteObject, and ListObjectVersions
  by prefix. An unversioned DELETE is refused, since the application must
  never issue one (DESIGN.md: Upload Intents).
  """

  import Plug.Conn

  @bucket "dz-bucket"
  @prefix "/" <> @bucket

  @type object :: %{version_id: String.t(), body: binary(), content_type: String.t() | nil}

  @doc """
  Starts an empty bucket under the test supervisor and installs it as the
  `DarkZenith.B2Stub` for the calling process. Returns the bucket handle.
  """
  def start! do
    bucket = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{objects: %{}, next: 1} end})
    Req.Test.stub(DarkZenith.B2Stub, &handle(&1, bucket))
    bucket
  end

  @doc "Every key holding at least one version, sorted."
  def keys(bucket) do
    bucket
    |> Agent.get(& &1.objects)
    |> Enum.filter(fn {_key, versions} -> versions != [] end)
    |> Enum.map(fn {key, _versions} -> key end)
    |> Enum.sort()
  end

  @doc "The object at `key` for the exact version, or the newest version when nil."
  @spec fetch(pid(), String.t(), String.t() | nil) :: object() | nil
  def fetch(bucket, key, version_id \\ nil) do
    versions = Agent.get(bucket, &Map.get(&1.objects, key, []))

    case version_id do
      nil -> List.first(versions)
      id -> Enum.find(versions, &(&1.version_id == id))
    end
  end

  ## Request handling

  # Plug entry points, for the end-to-end tests that serve the bucket over
  # HTTP from a Bandit listener: the plug option is the bucket handle.
  @behaviour Plug

  @impl Plug
  def init(bucket), do: bucket

  @impl Plug
  def call(conn, bucket), do: handle(conn, bucket)

  @doc false
  def handle(conn, bucket) do
    # Plug's default cache-control would violate the object contract.
    conn = conn |> fetch_query_params() |> delete_resp_header("cache-control")

    case {conn.method, key_of(conn)} do
      {"PUT", key} when is_binary(key) -> put_object(conn, bucket, key)
      {"HEAD", key} when is_binary(key) -> head_object(conn, bucket, key)
      {"GET", nil} -> list_versions(conn, bucket)
      {"GET", key} -> get_object(conn, bucket, key)
      {"DELETE", key} when is_binary(key) -> delete_object(conn, bucket, key)
      _other -> send_resp(conn, 405, "")
    end
  end

  defp key_of(%{request_path: @prefix <> "/" <> key}), do: key
  defp key_of(%{request_path: @prefix}), do: nil
  defp key_of(_conn), do: nil

  defp put_object(conn, bucket, key) do
    case get_req_header(conn, "x-amz-copy-source") do
      [source] -> copy_object(conn, bucket, key, source)
      [] -> store_object(conn, bucket, key)
    end
  end

  # A client PUT is authorized by the presigned query; a server-side PUT by
  # the SigV4 Authorization header.
  defp store_object(conn, bucket, key) do
    signed? =
      Map.has_key?(conn.query_params, "X-Amz-Signature") or
        get_req_header(conn, "authorization") != []

    if signed? do
      {body, conn} = read_full_body(conn)
      version = store!(bucket, key, body, first_header(conn, "content-type"))

      conn
      |> put_resp_header("x-amz-version-id", version)
      |> send_resp(200, "")
    else
      send_resp(conn, 403, "")
    end
  end

  defp copy_object(conn, bucket, key, source) do
    with @prefix <> "/" <> rest <- source,
         [source_key, "versionId=" <> source_version] <- String.split(rest, "?", parts: 2),
         %{} = object <- fetch(bucket, source_key, source_version) do
      version = store!(bucket, key, object.body, first_header(conn, "content-type"))

      conn
      |> put_resp_header("x-amz-version-id", version)
      |> send_resp(200, ~s(<CopyObjectResult><ETag>"#{version}"</ETag></CopyObjectResult>))
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp head_object(conn, bucket, key) do
    case fetch(bucket, key, conn.query_params["versionId"]) do
      nil -> send_resp(conn, 404, "")
      object -> conn |> put_object_headers(object) |> send_resp(200, "")
    end
  end

  defp get_object(conn, bucket, key) do
    case fetch(bucket, key, conn.query_params["versionId"]) do
      nil -> send_resp(conn, 404, "")
      object -> conn |> put_object_headers(object) |> send_resp(200, object.body)
    end
  end

  defp delete_object(conn, bucket, key) do
    case conn.query_params["versionId"] do
      nil ->
        send_resp(conn, 400, "")

      version ->
        Agent.update(bucket, fn state ->
          update_in(state.objects[key], fn versions ->
            Enum.reject(versions || [], &(&1.version_id == version))
          end)
        end)

        send_resp(conn, 204, "")
    end
  end

  defp list_versions(conn, bucket) do
    prefix = conn.query_params["prefix"] || ""

    entries =
      for {key, versions} <- Agent.get(bucket, & &1.objects),
          String.starts_with?(key, prefix),
          object <- versions do
        "<Version><Key>#{key}</Key><VersionId>#{object.version_id}</VersionId></Version>"
      end

    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n<ListVersionsResult>) <>
        "<IsTruncated>false</IsTruncated>" <> Enum.join(entries) <> "</ListVersionsResult>"

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  ## Helpers

  defp store!(bucket, key, body, content_type) do
    Agent.get_and_update(bucket, fn state ->
      version = "4_zfake#{state.next}"
      object = %{version_id: version, body: body, content_type: content_type}

      state =
        state
        |> Map.update!(:next, &(&1 + 1))
        |> update_in([:objects, key], &[object | &1 || []])

      {version, state}
    end)
  end

  defp put_object_headers(conn, object) do
    conn
    |> put_resp_header("content-length", Integer.to_string(byte_size(object.body)))
    |> put_resp_header("x-amz-version-id", object.version_id)
    |> maybe_put_header("content-type", object.content_type)
  end

  defp maybe_put_header(conn, _name, nil), do: conn
  defp maybe_put_header(conn, name, value), do: put_resp_header(conn, name, value)

  defp first_header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc, chunk])
    end
  end
end
