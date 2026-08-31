defmodule DarkZenith.B2StubHelpers do
  @moduledoc """
  A full B2 stub covering the upload pipeline's staging HEAD/GET, final
  copy PUT, final HEAD, and DELETE calls for one intent and RPM binary.
  """

  import ExUnit.Assertions

  def stub_pipeline(intent, binary, opts \\ []) do
    staging = "/dz-bucket/" <> intent.staging_path
    length = Integer.to_string(byte_size(binary))
    copy_status = Keyword.get(opts, :copy_status, 200)

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      case {conn.method, conn.request_path} do
        {"HEAD", ^staging} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", length)
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zstaged")
          |> Plug.Conn.send_resp(200, "")

        {"GET", ^staging} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.send_resp(200, binary)

        {"PUT", "/dz-bucket/repos/" <> _} when copy_status == 200 ->
          assert [source] = Plug.Conn.get_req_header(conn, "x-amz-copy-source")
          assert source =~ "versionId="

          conn
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zfinal")
          |> Plug.Conn.send_resp(200, "<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")

        {"PUT", "/dz-bucket/repos/" <> _} ->
          Plug.Conn.send_resp(conn, copy_status, "")

        {"HEAD", "/dz-bucket/repos/" <> _} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", length)
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_zfinal")
          |> Plug.Conn.send_resp(200, "")

        {"DELETE", _} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end
end
