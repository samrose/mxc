defmodule Mxc.Coordinator do
  @moduledoc """
  The Coordinator context manages the cluster of agents and workload scheduling.

  Uses Ecto for CRUD operations (source of truth) and datalox FactStore
  for rule-based decisions (scheduling, health, lifecycle).
  """

  import Ecto.Query

  alias Mxc.Repo
  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent, SchedulingRule}
  alias Mxc.Coordinator.{Dispatcher, FactStore}

  # ── Nodes ──────────────────────────────────────────────────────────

  def list_nodes do
    Node
    |> order_by([n], n.hostname)
    |> Repo.all()
  end

  def get_node(id) do
    case Repo.get(Node, id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  def create_node(attrs) do
    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast(:nodes, :create)
  end

  def update_node(%Node{} = node, attrs) do
    node
    |> Node.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast(:nodes, :update)
  end

  def delete_node(%Node{} = node) do
    Repo.delete(node)
    |> tap_broadcast(:nodes, :delete)
  end

  def heartbeat_node(id, status_attrs \\ %{}) do
    case Repo.get(Node, id) do
      nil ->
        {:error, :not_found}

      node ->
        attrs = Map.merge(status_attrs, %{last_heartbeat_at: DateTime.utc_now()})

        node
        |> Node.changeset(attrs)
        |> Repo.update()
        |> tap_broadcast(:nodes, :update)
    end
  end

  # ── Workloads ──────────────────────────────────────────────────────

  def list_workloads do
    Workload
    |> order_by([w], [desc: w.inserted_at])
    |> Repo.all()
  end

  def get_workload(id) do
    case Repo.get(Workload, id) do
      nil -> {:error, :not_found}
      workload -> {:ok, workload}
    end
  end

  @doc """
  Deploys a workload: validates platform support, creates it in Postgres,
  uses FactStore/datalox rules to find the best node via Datalog-derived
  placement candidates, then dispatches to the Agent Executor to actually
  run it.
  """
  def deploy_workload(attrs) do
    type = to_string(attrs[:type] || attrs["type"] || "process")

    # Validate workload type against platform capabilities
    with :ok <- Mxc.Platform.validate_workload_type(type) do
      workload_attrs = %{
        type: type,
        status: "pending",
        command: attrs[:command] || attrs["command"],
        args: attrs[:args] || attrs["args"] || [],
        env: attrs[:env] || attrs["env"] || %{},
        cpu_required: attrs[:cpu] || attrs["cpu"] || attrs[:cpu_required] || 1,
        memory_required: attrs[:memory_mb] || attrs["memory_mb"] || attrs[:memory_required] || 256,
        constraints: build_constraints(type, attrs)
      }

      with {:ok, workload} <- create_workload(workload_attrs) do
        # Use FactStore/datalox rules for placement, then dispatch to Executor
        place_and_dispatch(workload)
      end
    end
  end

  def stop_workload(id) do
    case Repo.get(Workload, id) do
      nil ->
        {:error, :not_found}

      workload ->
        if workload.status in ["running", "starting"] do
          with {:ok, updated} <-
                 workload
                 |> Workload.changeset(%{status: "stopping"})
                 |> Repo.update()
                 |> tap_broadcast(:workloads, :update) do
            # Dispatch stop to the Executor
            try do
              Dispatcher.dispatch_stop(updated)
            catch
              :exit, _ -> :ok
            end

            {:ok, updated}
          end
        else
          {:error, :invalid_state}
        end
    end
  end

  @doc """
  Execute a command inside a running workload.

  For microVM workloads, uses SSH to connect to the guest VM using its hostname.
  For process workloads, runs the command in the same environment.

  Returns `{:ok, output}` or `{:error, reason}`.

  ## Options

    * `:timeout` - command timeout in milliseconds (default: 30_000)
  """
  def exec_in_workload(workload_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, workload} <- get_workload(workload_id),
         :ok <- ensure_running(workload) do
      workload
      |> build_exec_command(command)
      |> run_command(timeout)
    end
  end

  @doc """
  Discover and store the IP address of a running workload.

  Queries the workload's network interface and stores the IP in the workload record.
  Returns `{:ok, updated_workload}` or `{:error, reason}`.
  """
  def discover_workload_ip(workload_id) do
    with {:ok, output} <- exec_in_workload(workload_id, "hostname -I | awk '{print $1}'"),
         {:ok, workload} <- get_workload(workload_id) do
      case String.trim(output) do
        "" -> {:error, :no_ip_found}
        ip -> update_workload(workload, %{ip: ip})
      end
    end
  end

  def create_workload(attrs) do
    %Workload{}
    |> Workload.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast(:workloads, :create)
  end

  def update_workload(%Workload{} = workload, attrs) do
    workload
    |> Workload.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast(:workloads, :update)
  end

  # ── Workload Events ────────────────────────────────────────────────

  def list_workload_events(workload_id) do
    WorkloadEvent
    |> where([e], e.workload_id == ^workload_id)
    |> order_by([e], [desc: e.inserted_at])
    |> Repo.all()
  end

  def create_workload_event(attrs) do
    %WorkloadEvent{}
    |> WorkloadEvent.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast(:workload_events, :create)
  end

  # ── Scheduling Rules ───────────────────────────────────────────────

  def list_scheduling_rules do
    SchedulingRule
    |> order_by([r], r.priority)
    |> Repo.all()
  end

  def get_scheduling_rule(id) do
    case Repo.get(SchedulingRule, id) do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  end

  def create_scheduling_rule(attrs) do
    %SchedulingRule{}
    |> SchedulingRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_scheduling_rule(%SchedulingRule{} = rule, attrs) do
    rule
    |> SchedulingRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_scheduling_rule(%SchedulingRule{} = rule) do
    Repo.delete(rule)
  end

  # ── Cluster Status ─────────────────────────────────────────────────

  def cluster_status do
    nodes = list_nodes()
    workloads = list_workloads()
    now = DateTime.utc_now()

    healthy_count =
      Enum.count(nodes, fn n ->
        n.status == "available" and n.last_heartbeat_at != nil and
          DateTime.diff(now, n.last_heartbeat_at, :second) < 30
      end)

    total_cpu = Enum.sum(Enum.map(nodes, & &1.cpu_total))
    total_memory = Enum.sum(Enum.map(nodes, & &1.memory_total))
    used_cpu = Enum.sum(Enum.map(nodes, & &1.cpu_used))
    used_memory = Enum.sum(Enum.map(nodes, & &1.memory_used))

    %{
      node_count: length(nodes),
      nodes_healthy: healthy_count,
      workload_count: length(workloads),
      workloads_running: Enum.count(workloads, &(&1.status == "running")),
      total_cpu: total_cpu,
      total_memory: total_memory,
      available_cpu: total_cpu - used_cpu,
      available_memory: total_memory - used_memory
    }
  end

  # ── FactStore Queries (delegated) ─────────────────────────────────

  defdelegate can_transition?(workload_id, next_status), to: FactStore
  defdelegate stale_nodes(), to: FactStore
  defdelegate overloaded_nodes(), to: FactStore

  # ── Private ────────────────────────────────────────────────────────

  defp place_and_dispatch(workload) do
    broadcast_fact_change(:workloads, :create, workload)

    try do
      FactStore.evaluate()
      candidates = FactStore.placement_candidates(workload.id)

      case candidates do
        [] ->
          {:ok, workload}

        _ ->
          # Datalox rules derived placement_candidate(Workload, Node, CpuFree, MemFree)
          # Pick the node with most available resources (spread strategy)
          {_, [_, node_id, _, _]} =
            Enum.max_by(candidates, fn {_, [_, _, cpu, mem]} -> cpu + mem end)

          case workload
               |> Workload.changeset(%{node_id: node_id, status: "starting"})
               |> Repo.update() do
            {:ok, placed} ->
              broadcast_fact_change(:workloads, :update, placed)

              # Actually dispatch to the Executor to run the workload
              try do
                Dispatcher.dispatch_start(placed)
              catch
                :exit, _ -> :ok
              end

              {:ok, placed}

            {:error, _changeset} ->
              {:ok, workload}
          end
      end
    catch
      :exit, _ ->
        # FactStore not running (e.g. in tests)
        {:ok, workload}
    end
  end

  defp build_constraints(type, attrs) do
    base = attrs[:constraints] || attrs["constraints"] || %{}

    case type do
      "microvm" ->
        # Auto-add microvm capability constraint so datalox rules
        # only place on nodes that can run VMs
        Map.put(base, "microvm", "true")

      _ ->
        base
    end
  end

  defp broadcast_fact_change(schema, action, record) do
    Phoenix.PubSub.broadcast(
      Mxc.PubSub,
      "fact_changes",
      {:fact_change, schema, action, record}
    )
  end

  defp tap_broadcast({:ok, record} = result, schema, action) do
    broadcast_fact_change(schema, action, record)
    result
  end

  defp tap_broadcast(error, _schema, _action), do: error

  defp ensure_running(%{status: "running"}), do: :ok
  defp ensure_running(_), do: {:error, :workload_not_running}

  # microvm: argv list — passed straight to execve, no host-side shell parsing.
  # The remote sshd still hands `command` to a shell on the guest, but that's
  # outside our trust boundary.
  defp build_exec_command(%{type: "microvm"} = workload, command) do
    hostname = derive_hostname(workload.command)

    [
      ~c"ssh",
      ~c"-o", ~c"StrictHostKeyChecking=no",
      ~c"-o", ~c"UserKnownHostsFile=/dev/null",
      ~c"-o", ~c"ConnectTimeout=10",
      to_charlist("root@#{hostname}"),
      to_charlist(command)
    ]
  end

  # process: charlist form — erlexec runs via /bin/sh -c, matching the
  # convention in Mxc.Agent.Executor.start_process/1.
  defp build_exec_command(%{type: "process"}, command), do: to_charlist(command)

  defp run_command(cmd, timeout) do
    case :exec.run(cmd, [:stdout, :stderr, :monitor, {:kill_timeout, 5}]) do
      {:ok, pid, os_pid} ->
        deadline = System.monotonic_time(:millisecond) + timeout
        collect_output(pid, os_pid, deadline, [])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_output(pid, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stdout, ^os_pid, data} ->
        collect_output(pid, os_pid, deadline, [acc, data])

      {:stderr, ^os_pid, data} ->
        collect_output(pid, os_pid, deadline, [acc, data])

      {:DOWN, _ref, :process, ^pid, :normal} ->
        {:ok, acc |> IO.iodata_to_binary() |> String.trim()}

      {:DOWN, _ref, :process, ^pid, {:exit_status, status}} ->
        output = acc |> IO.iodata_to_binary() |> String.trim()
        {:error, {:exit_code, decode_exit_status(status), output}}
    after
      remaining ->
        :exec.stop(os_pid)
        {:error, :timeout}
    end
  end

  defp decode_exit_status(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _signal, _core} -> -1
    end
  end

  defp derive_hostname(config_name) do
    String.replace(config_name, ~r/-(aarch64|x86_64)$/, "")
  end
end
