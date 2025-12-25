defmodule Mxc.Coordinator do
  @moduledoc """
  The Coordinator context manages the cluster of agents and workload scheduling.

  The coordinator is responsible for:
  - Discovering and tracking agent nodes via libcluster
  - Scheduling workloads onto available agents
  - Monitoring agent health and handling failover
  - Persisting state to PostgreSQL
  """

  alias Mxc.Coordinator.{NodeManager, Scheduler, Workload}

  @doc """
  Returns list of all connected agent nodes with their status.
  """
  def list_nodes do
    NodeManager.list_nodes()
  end

  @doc """
  Returns details for a specific node.
  """
  def get_node(node_id) do
    NodeManager.get_node(node_id)
  end

  @doc """
  Deploys a workload to the cluster.
  Returns {:ok, workload} or {:error, reason}.
  """
  def deploy_workload(spec) do
    with {:ok, node} <- Scheduler.place(spec),
         {:ok, workload} <- Workload.start(node, spec) do
      {:ok, workload}
    end
  end

  @doc """
  Lists all workloads across the cluster.
  """
  def list_workloads do
    Workload.list_all()
  end

  @doc """
  Gets a specific workload by ID.
  """
  def get_workload(id) do
    Workload.get(id)
  end

  @doc """
  Stops a running workload.
  """
  def stop_workload(id) do
    Workload.stop(id)
  end

  @doc """
  Returns overall cluster status.
  """
  def cluster_status do
    nodes = list_nodes()
    workloads = list_workloads()

    %{
      node_count: length(nodes),
      nodes_healthy: Enum.count(nodes, & &1.healthy),
      workload_count: length(workloads),
      workloads_running: Enum.count(workloads, &(&1.status == :running)),
      total_cpu: Enum.sum(Enum.map(nodes, & &1.cpu_cores)),
      total_memory_mb: Enum.sum(Enum.map(nodes, & &1.memory_mb)),
      available_cpu: Enum.sum(Enum.map(nodes, & &1.available_cpu)),
      available_memory_mb: Enum.sum(Enum.map(nodes, & &1.available_memory_mb))
    }
  end
end
