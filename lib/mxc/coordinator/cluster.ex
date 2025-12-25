defmodule Mxc.Coordinator.Cluster do
  @moduledoc """
  Configures libcluster topology based on runtime config.

  Supports:
  - :postgres (libcluster_postgres) - default, uses shared postgres for discovery
  - :gossip (libcluster Gossip) - for local dev/testing
  - :dns (libcluster DNSPoll) - for kubernetes-style discovery
  """

  @doc """
  Returns the libcluster topology configuration based on the configured strategy.
  """
  def topologies do
    strategy = Application.get_env(:mxc, :cluster_strategy, :gossip)
    topology_for(strategy)
  end

  @doc """
  Returns the configured cluster strategy.
  """
  def strategy do
    Application.get_env(:mxc, :cluster_strategy, :gossip)
  end

  defp topology_for(:postgres) do
    [
      mxc: [
        strategy: LibclusterPostgres.Strategy,
        config: [
          hostname: Application.get_env(:mxc, :database_host, "localhost"),
          port: Application.get_env(:mxc, :database_port, 5432),
          username: Application.get_env(:mxc, :database_user, "mxc"),
          password: Application.get_env(:mxc, :database_password, ""),
          database: Application.get_env(:mxc, :database_name, "mxc_dev"),
          channel_name: "mxc_cluster",
          heartbeat_interval: 5_000
        ]
      ]
    ]
  end

  defp topology_for(:gossip) do
    [
      mxc: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: Application.get_env(:mxc, :gossip_port, 45892),
          if_addr: "0.0.0.0",
          multicast_addr: "230.1.1.251",
          multicast_ttl: 1,
          secret: Application.get_env(:mxc, :gossip_secret, "mxc-dev-secret")
        ]
      ]
    ]
  end

  defp topology_for(:dns) do
    [
      mxc: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,
          query: Application.get_env(:mxc, :dns_query, "mxc.local"),
          node_basename: Application.get_env(:mxc, :node_basename, "mxc")
        ]
      ]
    ]
  end

  defp topology_for(:epmd) do
    # Simple EPMD-based clustering for testing
    [
      mxc: [
        strategy: Cluster.Strategy.Epmd,
        config: [
          hosts: Application.get_env(:mxc, :cluster_hosts, [])
        ]
      ]
    ]
  end

  defp topology_for(_unknown) do
    # Default to no clustering
    []
  end
end
