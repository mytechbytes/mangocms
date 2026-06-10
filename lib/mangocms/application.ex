defmodule MangoCMS.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MangoCMSWeb.Telemetry,
      MangoCMS.Repo,
      {DNSCluster, query: Application.get_env(:mangocms, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MangoCMS.PubSub},
      # Start a worker by calling: MangoCMS.Worker.start_link(arg)
      # {MangoCMS.Worker, arg},
      # Start to serve requests, typically the last entry
      MangoCMSWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MangoCMS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MangoCMSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
