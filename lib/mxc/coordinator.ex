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
end
