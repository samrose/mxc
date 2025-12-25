defmodule Mxc.Agent.Executor do
  @moduledoc """
  Executes and manages workloads on the local node.

  Supports two types of workloads:
  - :process - System processes managed via erlexec
  - :microvm - MicroVMs managed via the configured hypervisor
  """

  use GenServer
  require Logger

  alias Mxc.Agent.VMManager

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a workload based on its specification.
  """
  def start_workload(workload) do
    GenServer.call(__MODULE__, {:start_workload, workload}, 30_000)
  end

  @doc """
  Stops a running workload.
  """
  def stop_workload(workload_id) do
    GenServer.call(__MODULE__, {:stop_workload, workload_id})
  end

  @doc """
  Lists all workloads managed by this executor.
  """
  def list_workloads do
    GenServer.call(__MODULE__, :list_workloads)
  end

  @doc """
  Gets info about a specific workload.
  """
  def get_workload(workload_id) do
    GenServer.call(__MODULE__, {:get_workload, workload_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Start erlexec port program
    :exec.start([])

    {:ok, %{workloads: %{}}}
  end

  @impl true
  def handle_call({:start_workload, workload}, _from, state) do
    spec = workload.spec

    result =
      case workload.type do
        :process -> start_process(workload.id, spec)
        :microvm -> start_microvm(workload.id, spec)
        _ -> {:error, :unknown_workload_type}
      end

    case result do
      {:ok, local_state} ->
        Logger.info("Started workload #{workload.id}: #{inspect(spec[:command] || spec[:name])}")

        workload_entry = %{
          id: workload.id,
          type: workload.type,
          spec: spec,
          local_state: local_state,
          started_at: DateTime.utc_now()
        }

        # Notify coordinator that workload is running
        notify_coordinator(workload.id, :running)

        new_state = put_in(state.workloads[workload.id], workload_entry)
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to start workload #{workload.id}: #{inspect(reason)}")
        notify_coordinator(workload.id, :failed, %{error: inspect(reason)})
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_workload, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workload ->
        stop_result =
          case workload.type do
            :process -> stop_process(workload.local_state)
            :microvm -> stop_microvm(workload.local_state)
          end

        case stop_result do
          :ok ->
            Logger.info("Stopped workload #{workload_id}")
            notify_coordinator(workload_id, :stopped)
            {:reply, :ok, %{state | workloads: Map.delete(state.workloads, workload_id)}}

          {:error, reason} = error ->
            Logger.error("Failed to stop workload #{workload_id}: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:list_workloads, _from, state) do
    workloads =
      state.workloads
      |> Map.values()
      |> Enum.map(fn w ->
        %{
          id: w.id,
          type: w.type,
          spec: w.spec,
          started_at: w.started_at
        }
      end)

    {:reply, workloads, state}
  end

  @impl true
  def handle_call({:get_workload, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil -> {:reply, {:error, :not_found}, state}
      workload -> {:reply, {:ok, workload}, state}
    end
  end

  @impl true
  def handle_cast({:stop_workload, workload_id}, state) do
    # Async version for coordinator requests
    case Map.get(state.workloads, workload_id) do
      nil ->
        {:noreply, state}

      workload ->
        case workload.type do
          :process -> stop_process(workload.local_state)
          :microvm -> stop_microvm(workload.local_state)
        end

        notify_coordinator(workload_id, :stopped)
        {:noreply, %{state | workloads: Map.delete(state.workloads, workload_id)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Handle process termination
    case find_workload_by_pid(state.workloads, pid) do
      nil ->
        {:noreply, state}

      {workload_id, _workload} ->
        Logger.warning("Workload #{workload_id} exited: #{inspect(reason)}")

        status = if reason == :normal, do: :stopped, else: :failed
        error = if reason != :normal, do: inspect(reason), else: nil

        notify_coordinator(workload_id, status, %{error: error})

        {:noreply, %{state | workloads: Map.delete(state.workloads, workload_id)}}
    end
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, state) do
    Logger.debug("Workload [#{os_pid}] stdout: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, state) do
    Logger.debug("Workload [#{os_pid}] stderr: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Executor received: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp start_process(_workload_id, spec) do
    command = spec[:command] || raise "Process workload requires :command"
    args = spec[:args] || []
    env = spec[:env] || []
    cwd = spec[:cwd] || "/tmp"

    full_command =
      case args do
        [] -> command
        args when is_list(args) -> Enum.join([command | args], " ")
      end

    exec_opts = [
      :stdout,
      :stderr,
      :monitor,
      {:kill_timeout, spec[:kill_timeout] || 5000},
      {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)},
      {:cd, to_charlist(cwd)}
    ]

    case :exec.run_link(to_charlist(full_command), exec_opts) do
      {:ok, pid, os_pid} ->
        {:ok, %{pid: pid, os_pid: os_pid, command: command}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_microvm(_workload_id, spec) do
    VMManager.start_vm(spec)
  end

  defp stop_process(%{os_pid: os_pid}) do
    :exec.stop(os_pid)
    :ok
  end

  defp stop_microvm(local_state) do
    VMManager.stop_vm(local_state)
  end

  defp find_workload_by_pid(workloads, pid) do
    Enum.find(workloads, fn {_id, w} ->
      w.type == :process and w.local_state[:pid] == pid
    end)
  end

  defp notify_coordinator(workload_id, status, metadata \\ %{})

  defp notify_coordinator(workload_id, status, metadata) do
    # Find coordinator node and send status update
    case find_coordinator_node() do
      nil ->
        Logger.warning("No coordinator node found to report status update")

      coordinator ->
        GenServer.cast(
          {Mxc.Coordinator.Workload, coordinator},
          {:update_status, workload_id, status, metadata}
        )
    end
  end

  defp find_coordinator_node do
    Node.list()
    |> Enum.find(fn node ->
      node |> Atom.to_string() |> String.starts_with?("coordinator@")
    end)
  end
end
