defmodule Mxc.Agent.Health do
  @moduledoc """
  Reports agent health and resource availability to the coordinator.

  Periodically sends heartbeats with:
  - CPU cores available
  - Memory available
  - Running workloads
  - Hypervisor status
  """

  use GenServer
  require Logger

  @heartbeat_interval_ms 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current node information.
  """
  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  @doc """
  Triggers an immediate status report to the coordinator.
  """
  def report_now do
    GenServer.cast(__MODULE__, :report_now)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule first heartbeat
    schedule_heartbeat()

    state = %{
      cpu_cores: detect_cpu_cores(),
      memory_mb: detect_memory_mb(),
      hypervisor: Application.get_env(:mxc, :hypervisor)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = build_status(state)
    {:reply, info, state}
  end

  @impl true
  def handle_cast(:report_now, state) do
    report_to_coordinator(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:report_status, state) do
    # Called by coordinator when node connects
    report_to_coordinator(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    report_to_coordinator(state)
    schedule_heartbeat()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp report_to_coordinator(state) do
    status = build_status(state)

    # Find coordinator node and send status
    coordinator_nodes =
      Node.list()
      |> Enum.filter(&coordinator_node?/1)

    case coordinator_nodes do
      [coordinator | _] ->
        GenServer.cast(
          {Mxc.Coordinator.NodeManager, coordinator},
          {:report_status, node(), status}
        )

      [] ->
        Logger.debug("No coordinator node found, skipping heartbeat")
    end
  end

  defp build_status(state) do
    workloads = Mxc.Agent.Executor.list_workloads()
    {used_cpu, used_memory} = calculate_resource_usage(workloads)

    %{
      cpu_cores: state.cpu_cores,
      memory_mb: state.memory_mb,
      available_cpu: max(0, state.cpu_cores - used_cpu),
      available_memory_mb: max(0, state.memory_mb - used_memory),
      workloads: Enum.map(workloads, & &1.id),
      hypervisor: state.hypervisor
    }
  end

  defp calculate_resource_usage(workloads) do
    Enum.reduce(workloads, {0, 0}, fn w, {cpu, mem} ->
      {
        cpu + (w.spec[:cpu] || 0),
        mem + (w.spec[:memory_mb] || 0)
      }
    end)
  end

  defp coordinator_node?(node) do
    node
    |> Atom.to_string()
    |> String.starts_with?("coordinator@")
  end

  defp detect_cpu_cores do
    # Check config first, then auto-detect
    case Application.get_env(:mxc, :cpu_cores, 0) do
      0 -> System.schedulers_online()
      n -> n
    end
  end

  defp detect_memory_mb do
    # Check config first, then auto-detect
    case Application.get_env(:mxc, :memory_mb, 0) do
      0 -> detect_system_memory_mb()
      n -> n
    end
  end

  defp detect_system_memory_mb do
    # Try to detect system memory
    case :os.type() do
      {:unix, :darwin} ->
        # macOS
        case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.trim()
            |> String.to_integer()
            |> div(1024 * 1024)

          _ ->
            4096
        end

      {:unix, _} ->
        # Linux
        case File.read("/proc/meminfo") do
          {:ok, content} ->
            case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
              [_, kb] -> div(String.to_integer(kb), 1024)
              _ -> 4096
            end

          _ ->
            4096
        end

      _ ->
        4096
    end
  end
end
