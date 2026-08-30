defmodule DarkZenith.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DarkZenithWeb.Telemetry,
      DarkZenith.Repo,
      {DNSCluster, query: Application.get_env(:dark_zenith, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DarkZenith.PubSub},
      # Start a worker by calling: DarkZenith.Worker.start_link(arg)
      # {DarkZenith.Worker, arg},
      # Start to serve requests, typically the last entry
      DarkZenithWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DarkZenith.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DarkZenithWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
