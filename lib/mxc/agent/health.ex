defmodule Mxc.Agent.Health do
  @moduledoc """
  Reports agent health and resource availability to the coordinator.

  Periodically sends heartbeats with resource usage to the coordinator
  via RPC, which writes to Postgres and syncs to the FactStore.
  """

  use GenServer
  require Logger

  @heartbeat_interval_ms 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  def report_now do
    GenServer.cast(__MODULE__, :report_now)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    schedule_heartbeat()

    state = %{
      node_id: Application.get_env(:mxc, :node_id),
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
    case state.node_id do
      nil ->
        Logger.debug("No node_id configured, skipping heartbeat")

      node_id ->
        status = build_status(state)

        attrs = %{
          cpu_used: status.cpu_cores - status.available_cpu,
          memory_used: status.memory_mb - status.available_memory_mb,
          status: "available"
        }

        case find_coordinator_node() do
          nil ->
            Logger.debug("No coordinator node found, skipping heartbeat")

          coordinator ->
            case :rpc.call(coordinator, Mxc.Coordinator, :heartbeat_node, [node_id, attrs]) do
              {:ok, _node} ->
                :ok

              {:error, :not_found} ->
                Logger.warning("Node #{node_id} not registered on coordinator, cannot heartbeat")

              {:badrpc, reason} ->
                Logger.debug("RPC to coordinator failed: #{inspect(reason)}")

              other ->
                Logger.debug("Heartbeat result: #{inspect(other)}")
            end
        end
    end
  end

  defp build_status(state) do
    workloads =
      try do
        Mxc.Agent.Executor.list_workloads()
      catch
        :exit, _ -> []
      end

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

  defp find_coordinator_node do
    Node.list()
    |> Enum.find(fn node ->
      node |> Atom.to_string() |> String.starts_with?("coordinator@")
    end)
  end

  defp detect_cpu_cores do
    case Application.get_env(:mxc, :cpu_cores, 0) do
      0 -> System.schedulers_online()
      n -> n
    end
  end

  defp detect_memory_mb do
    case Application.get_env(:mxc, :memory_mb, 0) do
      0 -> detect_system_memory_mb()
      n -> n
    end
  end

  defp detect_system_memory_mb do
    case :os.type() do
      {:unix, :darwin} ->
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
