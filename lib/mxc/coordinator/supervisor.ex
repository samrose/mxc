defmodule Mxc.Coordinator.Supervisor do
  @moduledoc """
  Supervisor for the coordinator subsystem.

  Starts and supervises:
  - Cluster topology (libcluster)
  - NodeManager (tracks connected agents)
  - Workload manager
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    topologies = Mxc.Coordinator.Cluster.topologies()

    children = [
      # Cluster topology for discovering agents
      {Cluster.Supervisor, [topologies, [name: Mxc.ClusterSupervisor]]},

      # Node manager tracks agent nodes
      Mxc.Coordinator.NodeManager,

      # Workload lifecycle manager
      Mxc.Coordinator.Workload
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
