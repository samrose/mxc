defmodule Mxc.Coordinator.Supervisor do
  @moduledoc """
  Supervisor for the coordinator subsystem.

  Starts and supervises:
  - Cluster topology (libcluster)
  - FactStore (datalox rules engine)
  - Reactor (acts on derived facts)
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

      # FactStore: datalox database + rule evaluation
      Mxc.Coordinator.FactStore,

      # Reactor: subscribes to derived facts, executes side effects
      Mxc.Coordinator.Reactor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
