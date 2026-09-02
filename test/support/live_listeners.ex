defmodule DarkZenith.LiveListeners do
  @moduledoc """
  Serves the application and the in-memory bucket over real HTTP, for
  end-to-end tests whose clients are separate processes: a dnf container,
  or the shell scripts under `deploy/`.

  The endpoint runs without its own listener in test, and the URLs it
  serves (the `.repo` baseurl, the `gpgkey` link) carry the port
  `DarkZenithWeb.Endpoint.url/0` names, so `start!/0` puts a Bandit
  listener on exactly that port. A second listener on a free port serves a
  fresh `DarkZenith.FakeBucket`, and the B2 endpoint setting is pointed at
  it so presigned upload and download URLs resolve there; the pipeline's
  own object-storage calls keep going through the Req.Test stub
  (`FakeBucket.start!/0`). Everything starts under the test supervisor and
  is restored on exit.

  Call from a non-async test: the endpoint port is fixed, and the listener
  processes serve requests from the caller's sandbox connection.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias DarkZenith.FakeBucket

  @doc "Starts both listeners and returns the bucket handle."
  def start! do
    bucket = FakeBucket.start!()
    serve_bucket!(bucket)
    serve_endpoint!()
    bucket
  end

  defp serve_endpoint! do
    %URI{host: "localhost", port: port} = URI.parse(DarkZenithWeb.Endpoint.url())

    start_supervised!(
      {Bandit, plug: DarkZenithWeb.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )
  end

  defp serve_bucket!(bucket) do
    listener =
      start_supervised!(
        {Bandit, plug: {FakeBucket, bucket}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    b2 = Application.fetch_env!(:dark_zenith, :b2)
    on_exit(fn -> Application.put_env(:dark_zenith, :b2, b2) end)
    Application.put_env(:dark_zenith, :b2, Keyword.put(b2, :endpoint, "http://127.0.0.1:#{port}"))
  end
end
