defmodule Mxc.Coordinator.NodeManager do
  @moduledoc """
  Manages the registry of connected agent nodes.

  Tracks:
  - Connected agent nodes
  - Their reported resources (cpu, memory, running workloads)
  - Health status
  - Last heartbeat
  """

  use GenServer
  require Logger

  @heartbeat_timeout_ms 30_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a list of all known nodes with their current status.
  """
  def list_nodes do
    GenServer.call(__MODULE__, :list_nodes)
  end

  @doc """
  Returns details for a specific node by its identifier.
  """
  def get_node(node_id) do
    GenServer.call(__MODULE__, {:get_node, node_id})
  end

  @doc """
  Returns only nodes that are healthy and available for scheduling.
  """
  def available_nodes do
    GenServer.call(__MODULE__, :available_nodes)
  end

  @doc """
  Called by agents to report their status.
  """
  def report_status(node, status) do
    GenServer.cast(__MODULE__, {:report_status, node, status})
  end

  @doc """
  Updates resource usage for a node after workload changes.
  """
  def update_resources(node, resources) do
    GenServer.cast(__MODULE__, {:update_resources, node, resources})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Monitor for node connections/disconnections
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Schedule periodic health checks
    schedule_health_check()

    {:ok, %{nodes: %{}}}
  end

  @impl true
  def handle_call(:list_nodes, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.map(&enrich_node_status/1)

    {:reply, nodes, state}
  end

  @impl true
  def handle_call({:get_node, node_id}, _from, state) do
    case Map.get(state.nodes, node_id) do
      nil -> {:reply, {:error, :not_found}, state}
      node -> {:reply, {:ok, enrich_node_status(node)}, state}
    end
  end

  @impl true
  def handle_call(:available_nodes, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.filter(&node_available?/1)
      |> Enum.map(&enrich_node_status/1)

    {:reply, nodes, state}
  end

  @impl true
  def handle_cast({:report_status, node, status}, state) do
    node_data = %{
      node: node,
      cpu_cores: status[:cpu_cores] || 0,
      memory_mb: status[:memory_mb] || 0,
      available_cpu: status[:available_cpu] || status[:cpu_cores] || 0,
      available_memory_mb: status[:available_memory_mb] || status[:memory_mb] || 0,
      workloads: status[:workloads] || [],
      hypervisor: status[:hypervisor],
      last_heartbeat: DateTime.utc_now(),
      connected_at: Map.get(state.nodes, node, %{})[:connected_at] || DateTime.utc_now()
    }

    Logger.debug("Node #{node} reported status: #{inspect(status)}")

    {:noreply, put_in(state.nodes[node], node_data)}
  end

  @impl true
  def handle_cast({:update_resources, node, resources}, state) do
    case Map.get(state.nodes, node) do
      nil ->
        {:noreply, state}

      node_data ->
        updated = Map.merge(node_data, resources)
        {:noreply, put_in(state.nodes[node], updated)}
    end
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node connected: #{node}")

    # Request status from the new node
    if is_agent_node?(node) do
      request_node_status(node)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Node disconnected: #{node}")

    # Broadcast node down event for failover handling
    Phoenix.PubSub.broadcast(Mxc.PubSub, "cluster:events", {:node_down, node})

    {:noreply, %{state | nodes: Map.delete(state.nodes, node)}}
  end

  @impl true
  def handle_info(:health_check, state) do
    now = DateTime.utc_now()

    # Check for stale nodes
    stale_nodes =
      state.nodes
      |> Enum.filter(fn {_node, data} ->
        DateTime.diff(now, data.last_heartbeat, :millisecond) > @heartbeat_timeout_ms
      end)
      |> Enum.map(fn {node, _} -> node end)

    # Log stale nodes
    Enum.each(stale_nodes, fn node ->
      Logger.warning("Node #{node} missed heartbeat, marking unhealthy")
    end)

    schedule_health_check()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 10_000)
  end

  defp enrich_node_status(node_data) do
    now = DateTime.utc_now()
    heartbeat_age = DateTime.diff(now, node_data.last_heartbeat, :millisecond)

    Map.merge(node_data, %{
      healthy: heartbeat_age < @heartbeat_timeout_ms,
      heartbeat_age_ms: heartbeat_age
    })
  end

  defp node_available?(node_data) do
    now = DateTime.utc_now()
    heartbeat_age = DateTime.diff(now, node_data.last_heartbeat, :millisecond)
    heartbeat_age < @heartbeat_timeout_ms
  end

  defp is_agent_node?(node) do
    # Check if the node name starts with "agent@"
    node
    |> Atom.to_string()
    |> String.starts_with?("agent@")
  end

  defp request_node_status(node) do
    # Send an async request to the agent to report its status
    GenServer.cast({Mxc.Agent.Health, node}, :report_status)
  end
end
