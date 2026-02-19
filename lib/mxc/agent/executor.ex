defmodule Mxc.Agent.Executor do
  @moduledoc """
  Executes and manages workloads on the local machine.

  Accepts Ecto Workload structs from the Coordinator (via Dispatcher)
  and runs them:
  - "process" type: system processes managed via erlexec
  - "microvm" type: NixOS microVMs managed via Mxc.Agent.MicroVM

  Reports status changes back to the Coordinator.
  """

  use GenServer
  require Logger

  alias Mxc.Agent.MicroVM
  alias Mxc.Coordinator.Schemas.Workload

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a workload. Accepts an Ecto Workload struct.
  Returns :ok or {:error, reason}.
  """
  def start_workload(%Workload{} = workload) do
    GenServer.call(__MODULE__, {:start_workload, workload}, 60_000)
  end

  @doc """
  Stops a running workload by ID.
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

  @doc """
  Executes a command inside a running workload's environment.
  For microVMs, uses SSH. For processes, runs in the same shell environment.
  Returns `{:ok, output}` or `{:error, reason}`.
  """
  def exec_in_workload(workload_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:exec_in_workload, workload_id, command, opts}, timeout + 5_000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Start erlexec port program for process workloads
    case :exec.start([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, %{workloads: %{}}}
  end

  @impl true
  def handle_call({:start_workload, %Workload{} = workload}, _from, state) do
    case workload.type do
      "microvm" ->
        # MicroVM builds can take minutes — launch async and reply immediately.
        # The spawned task sends {:microvm_started, ...} or {:microvm_failed, ...}
        # back to this GenServer when done.
        executor_pid = self()

        spawn(fn ->
          try do
            Logger.info("MicroVM build starting for #{workload.id}: #{workload.command}")
            result = start_microvm(workload)
            Logger.info("MicroVM build result for #{workload.id}: #{inspect(result)}")

            case result do
              {:ok, local_state} ->
                send(executor_pid, {:microvm_started, workload, local_state})

              {:error, reason} ->
                send(executor_pid, {:microvm_failed, workload, reason})
            end
          rescue
            e ->
              Logger.error("MicroVM build crashed for #{workload.id}: #{Exception.message(e)}")
              send(executor_pid, {:microvm_failed, workload, Exception.message(e)})
          catch
            kind, reason ->
              Logger.error("MicroVM build error for #{workload.id}: #{kind} #{inspect(reason)}")
              send(executor_pid, {:microvm_failed, workload, inspect({kind, reason})})
          end
        end)

        # Track as building so we know it's in progress
        entry = %{
          id: workload.id,
          type: workload.type,
          command: workload.command,
          local_state: %{kind: :microvm, status: :building},
          started_at: nil,
          cpu_required: workload.cpu_required,
          memory_required: workload.memory_required
        }

        {:reply, :ok, put_in(state.workloads[workload.id], entry)}

      type when type in ["process"] ->
        # Process starts are fast — handle synchronously
        result = start_process(workload)
        handle_sync_start_result(workload, result, state)

      other ->
        error = {:error, {:unknown_workload_type, other}}
        Logger.error("Failed to start workload #{workload.id}: unknown type #{other}")
        notify_coordinator(workload.id, "failed", %{error: "unknown workload type: #{other}"})
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_workload, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        stop_result =
          case entry.type do
            "process" -> stop_process(entry.local_state)
            "microvm" -> MicroVM.stop_vm(entry.local_state)
          end

        case stop_result do
          :ok ->
            Logger.info("Stopped workload #{workload_id}")
            notify_coordinator(workload_id, "stopped", %{stopped_at: DateTime.utc_now()})
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
          command: w.command,
          started_at: w.started_at,
          cpu_required: w.cpu_required,
          memory_required: w.memory_required
        }
      end)

    {:reply, workloads, state}
  end

  @impl true
  def handle_call({:get_workload, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call({:exec_in_workload, workload_id, command, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    result = case Map.get(state.workloads, workload_id) do
      nil ->
        {:error, :not_found}

      entry ->
        shell_cmd = case entry.type do
          "microvm" ->
            hostname = derive_hostname(entry.command)
            ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
            escaped = "'" <> String.replace(command, "'", "'\\''") <> "'"
            "ssh #{ssh_opts} root@#{hostname} #{escaped}"

          "process" ->
            command
        end

        run_shell_command(shell_cmd, timeout)
    end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:microvm_started, workload, local_state}, state) do
    Logger.info("MicroVM workload #{workload.id} started: #{workload.command}")

    # Monitor the VM process so we detect exit
    if local_state[:pid], do: Process.monitor(local_state[:pid])

    entry = %{
      id: workload.id,
      type: workload.type,
      command: workload.command,
      local_state: Map.put(local_state, :kind, :microvm),
      started_at: DateTime.utc_now(),
      cpu_required: workload.cpu_required,
      memory_required: workload.memory_required
    }

    notify_coordinator(workload.id, "running", %{started_at: DateTime.utc_now()})
    {:noreply, put_in(state.workloads[workload.id], entry)}
  end

  @impl true
  def handle_info({:microvm_failed, workload, reason}, state) do
    Logger.error("MicroVM workload #{workload.id} failed: #{inspect(reason)}")
    notify_coordinator(workload.id, "failed", %{error: inspect(reason)})
    {:noreply, %{state | workloads: Map.delete(state.workloads, workload.id)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_workload_by_pid(state.workloads, pid) do
      nil ->
        {:noreply, state}

      {workload_id, _entry} ->
        Logger.warning("Workload #{workload_id} exited: #{inspect(reason)}")

        status = if reason == :normal, do: "stopped", else: "failed"
        error = if reason != :normal, do: inspect(reason), else: nil

        notify_coordinator(workload_id, status, %{
          error: error,
          stopped_at: DateTime.utc_now()
        })

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

  # Private — Process workloads

  defp start_process(%Workload{} = workload) do
    command = workload.command || raise "process workload requires a command"
    args = workload.args || []

    full_command =
      case args do
        [] -> command
        args -> Enum.join([command | args], " ")
      end

    env =
      (workload.env || %{})
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    exec_opts = [
      :stdout,
      :stderr,
      :monitor,
      {:kill_timeout, 5000},
      {:env, env},
      {:cd, ~c"/tmp"}
    ]

    case :exec.run_link(to_charlist(full_command), exec_opts) do
      {:ok, pid, os_pid} ->
        {:ok, %{pid: pid, os_pid: os_pid, kind: :process}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_process(%{os_pid: os_pid}) do
    :exec.stop(os_pid)
    :ok
  end

  # Private — MicroVM workloads

  defp start_microvm(%Workload{} = workload) do
    # command field contains the nixosConfiguration name
    config_name = workload.command

    case Mxc.Platform.validate_workload_type("microvm") do
      :ok ->
        case MicroVM.start_vm(config_name) do
          {:ok, vm_state} ->
            {:ok, Map.put(vm_state, :kind, :microvm)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_sync_start_result(workload, result, state) do
    case result do
      {:ok, local_state} ->
        Logger.info("Started workload #{workload.id} (#{workload.type}): #{workload.command}")

        entry = %{
          id: workload.id,
          type: workload.type,
          command: workload.command,
          local_state: local_state,
          started_at: DateTime.utc_now(),
          cpu_required: workload.cpu_required,
          memory_required: workload.memory_required
        }

        notify_coordinator(workload.id, "running", %{started_at: DateTime.utc_now()})
        {:reply, :ok, put_in(state.workloads[workload.id], entry)}

      {:error, reason} = error ->
        Logger.error("Failed to start workload #{workload.id}: #{inspect(reason)}")
        notify_coordinator(workload.id, "failed", %{error: inspect(reason)})
        {:reply, error, state}
    end
  end

  # Private — Find workload by erlang pid

  defp find_workload_by_pid(workloads, pid) do
    Enum.find(workloads, fn {_id, w} ->
      w.local_state[:pid] == pid
    end)
  end

  # Private — Notify coordinator of status changes

  defp notify_coordinator(workload_id, status, metadata) do
    mode = Application.get_env(:mxc, :mode, :standalone)

    attrs = %{status: status}
    attrs = if metadata[:error], do: Map.put(attrs, :error, metadata[:error]), else: attrs
    attrs = if metadata[:started_at], do: Map.put(attrs, :started_at, metadata[:started_at]), else: attrs
    attrs = if metadata[:stopped_at], do: Map.put(attrs, :stopped_at, metadata[:stopped_at]), else: attrs

    case mode do
      m when m in [:standalone, :coordinator] ->
        # Same BEAM node — call Coordinator directly
        case Mxc.Coordinator.get_workload(workload_id) do
          {:ok, workload} ->
            Mxc.Coordinator.update_workload(workload, attrs)

          {:error, :not_found} ->
            Logger.warning("Workload #{workload_id} not found in coordinator")
        end

      :agent ->
        # Distributed — RPC to coordinator node
        case find_coordinator_node() do
          nil ->
            Logger.warning("No coordinator node found")

          coordinator ->
            case :rpc.call(coordinator, Mxc.Coordinator, :get_workload, [workload_id]) do
              {:ok, workload} ->
                :rpc.call(coordinator, Mxc.Coordinator, :update_workload, [workload, attrs])

              {:error, :not_found} ->
                Logger.warning("Workload #{workload_id} not found on coordinator")

              {:badrpc, reason} ->
                Logger.warning("RPC to coordinator failed: #{inspect(reason)}")
            end
        end
    end
  end

  defp find_coordinator_node do
    Node.list()
    |> Enum.find(fn node ->
      node |> Atom.to_string() |> String.starts_with?("coordinator@")
    end)
  end

  defp derive_hostname(config_name) do
    # Strip architecture suffix: "pg2une-postgres-aarch64" → "pg2une-postgres"
    config_name
    |> String.replace(~r/-(aarch64|x86_64)$/, "")
  end

  defp run_shell_command(command, timeout) do
    task = Task.async(fn ->
      System.cmd("bash", ["-c", command], stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit_code, code, String.trim(output)}}
      nil -> {:error, :timeout}
    end
  end
end
