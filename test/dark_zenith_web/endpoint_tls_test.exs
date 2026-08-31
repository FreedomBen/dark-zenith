defmodule DarkZenithWeb.EndpointTlsTest do
  # async: false — these tests rewrite the endpoint's application environment
  # to flip the configured URL scheme.
  use ExUnit.Case, async: false

  alias DarkZenithWeb.Endpoint

  defp put_url_scheme(scheme) do
    env = Application.get_env(:dark_zenith, Endpoint) || []
    url = Keyword.put(env[:url] || [], :scheme, scheme)
    Application.put_env(:dark_zenith, Endpoint, Keyword.put(env, :url, url))
    on_exit(fn -> Application.put_env(:dark_zenith, Endpoint, env) end)
  end

  defp call_tls_redirect(conn) do
    Plug.SSL.call(conn, Plug.SSL.init(Endpoint.tls_redirect_opts()))
  end

  describe "plain_http_deployment?/1" do
    test "false when no URL scheme is configured (https default)" do
      refute Endpoint.plain_http_deployment?(Plug.Test.conn(:get, "/"))
    end

    test "false when the configured URL scheme is https" do
      put_url_scheme("https")
      refute Endpoint.plain_http_deployment?(Plug.Test.conn(:get, "/"))
    end

    test "true when the configured URL scheme is http" do
      put_url_scheme("http")
      assert Endpoint.plain_http_deployment?(Plug.Test.conn(:get, "/"))
    end
  end

  describe "tls_redirect_opts/0 under Plug.SSL" do
    test "redirects a plain-HTTP request on a non-local host to the canonical https host" do
      put_url_scheme("https")

      conn = call_tls_redirect(%{Plug.Test.conn(:get, "/some/path") | host: "192.168.1.99"})

      assert conn.halted
      assert conn.status == 301
      assert Plug.Conn.get_resp_header(conn, "location") == ["https://localhost/some/path"]
    end

    test "does not redirect requests whose host is localhost or 127.0.0.1" do
      put_url_scheme("https")

      for host <- ["localhost", "127.0.0.1"] do
        refute call_tls_redirect(%{Plug.Test.conn(:get, "/") | host: host}).halted
      end
    end

    test "does not redirect when the deployment URL scheme is http" do
      put_url_scheme("http")

      refute call_tls_redirect(%{Plug.Test.conn(:get, "/") | host: "192.168.1.99"}).halted
    end

    test "honors X-Forwarded-Proto https (untrusted peers have it stripped earlier)" do
      put_url_scheme("https")

      conn =
        %{Plug.Test.conn(:get, "/") | host: "example.com"}
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> call_tls_redirect()

      refute conn.halted
      assert conn.scheme == :https
    end
  end
end
