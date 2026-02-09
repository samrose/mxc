defmodule Mxc.Agent.Health do
  @moduledoc """
  Reports agent health and resource availability to the coordinator.

  On startup, auto-registers the local machine as a node if running
  in standalone mode (or if configured with a node_id in agent mode).

  Periodically sends heartbeats with resource usage. In standalone mode,
  calls the Coordinator context directly. In agent mode, uses RPC.
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
    state = %{
      node_id: Application.get_env(:mxc, :node_id),
      cpu_cores: detect_cpu_cores(),
      memory_mb: detect_memory_mb(),
      hypervisor: detect_hypervisor()
    }

    # Auto-register in standalone mode
    state = maybe_auto_register(state)

    schedule_heartbeat()

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

  # Private

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp maybe_auto_register(state) do
    mode = Application.get_env(:mxc, :mode, :standalone)

    case {mode, state.node_id} do
      {:standalone, nil} ->
        # Auto-register this machine as a node
        hostname = detect_hostname()
        capabilities = Mxc.Platform.node_capabilities()

        attrs = %{
          hostname: hostname,
          status: "available",
          cpu_total: state.cpu_cores,
          memory_total: state.memory_mb,
          cpu_used: 0,
          memory_used: 0,
          hypervisor: hypervisor_string(state.hypervisor),
          capabilities: capabilities
        }

        case Mxc.Coordinator.create_node(attrs) do
          {:ok, node} ->
            Logger.info("Auto-registered local node: #{node.id} (#{hostname})")
            Application.put_env(:mxc, :node_id, node.id)
            %{state | node_id: node.id}

          {:error, %Ecto.Changeset{} = cs} ->
            # Might already exist (duplicate hostname) — find it
            case find_existing_node(hostname) do
              {:ok, node} ->
                Logger.info("Found existing node registration: #{node.id} (#{hostname})")
                Application.put_env(:mxc, :node_id, node.id)
                %{state | node_id: node.id}

              :not_found ->
                Logger.error("Failed to register node: #{inspect(cs.errors)}")
                state
            end
        end

      _ ->
        state
    end
  end

  defp find_existing_node(hostname) do
    Mxc.Coordinator.list_nodes()
    |> Enum.find(fn n -> n.hostname == hostname end)
    |> case do
      nil -> :not_found
      node -> {:ok, node}
    end
  end

  defp report_to_coordinator(state) do
    case state.node_id do
      nil ->
        Logger.debug("No node_id configured, skipping heartbeat")

      node_id ->
        status = build_status(state)
        mode = Application.get_env(:mxc, :mode, :standalone)

        attrs = %{
          cpu_used: state.cpu_cores - status.available_cpu,
          memory_used: state.memory_mb - status.available_memory_mb,
          status: "available"
        }

        case mode do
          m when m in [:standalone, :coordinator] ->
            # Same BEAM node — call directly
            case Mxc.Coordinator.heartbeat_node(node_id, attrs) do
              {:ok, _node} -> :ok
              {:error, :not_found} ->
                Logger.warning("Node #{node_id} not found, re-registering")
                # Node was deleted, clear node_id so next tick re-registers
              other ->
                Logger.debug("Heartbeat result: #{inspect(other)}")
            end

          :agent ->
            # Distributed — RPC to coordinator
            case find_coordinator_node() do
              nil ->
                Logger.debug("No coordinator node found, skipping heartbeat")

              coordinator ->
                case :rpc.call(coordinator, Mxc.Coordinator, :heartbeat_node, [node_id, attrs]) do
                  {:ok, _node} -> :ok
                  {:error, :not_found} ->
                    Logger.warning("Node #{node_id} not registered on coordinator")
                  {:badrpc, reason} ->
                    Logger.debug("RPC to coordinator failed: #{inspect(reason)}")
                  other ->
                    Logger.debug("Heartbeat result: #{inspect(other)}")
                end
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
        cpu + (w[:cpu_required] || 0),
        mem + (w[:memory_required] || 0)
      }
    end)
  end

  defp find_coordinator_node do
    Node.list()
    |> Enum.find(fn node ->
      node |> Atom.to_string() |> String.starts_with?("coordinator@")
    end)
  end

  defp detect_hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  defp detect_hypervisor do
    # Use configured value or auto-detect
    case Application.get_env(:mxc, :hypervisor) do
      nil -> Mxc.Platform.preferred_hypervisor()
      hv when is_atom(hv) -> hv
      hv when is_binary(hv) -> String.to_atom(hv)
    end
  end

  defp hypervisor_string(nil), do: nil
  defp hypervisor_string(hv), do: to_string(hv)

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
