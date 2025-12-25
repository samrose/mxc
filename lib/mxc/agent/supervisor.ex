defmodule Mxc.Agent.Supervisor do
  @moduledoc """
  Supervisor for the agent subsystem.

  Starts and supervises:
  - Cluster topology (libcluster) for connecting to coordinator
  - Executor (runs workloads)
  - Health reporter (sends heartbeats)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    topologies = Mxc.Coordinator.Cluster.topologies()

    children = [
      # Cluster topology for connecting to coordinator
      {Cluster.Supervisor, [topologies, [name: Mxc.AgentClusterSupervisor]]},

      # Workload executor
      Mxc.Agent.Executor,

      # Health reporter
      Mxc.Agent.Health
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
