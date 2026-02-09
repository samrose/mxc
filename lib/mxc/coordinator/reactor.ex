defmodule Mxc.Coordinator.Reactor do
  @moduledoc """
  Subscribes to derived facts from FactStore and executes side effects.

  Actions:
  - node_stale(NodeId) → Set node status to :unavailable
  - should_fail(WorkloadId) → RPC agent to stop, set workload to :failed
  - workload_orphaned(WorkloadId) → Set workload to :failed, clear placement
  - can_restart(WorkloadId) → Run select_node, start on best node
  - node_overloaded(NodeId) → Log warning

  The Reactor is idempotent — duplicate derivations are safe.
  """

  use GenServer
  require Logger

  alias Mxc.Coordinator.Schemas.{Node, Workload}
  alias Mxc.Coordinator.{Dispatcher, FactStore}
  alias Mxc.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Mxc.PubSub, "derived_facts")
    {:ok, %{last_acted: %{}}}
  end

  @impl true
  def handle_info({:derived_facts, derived}, state) do
    state =
      try do
        process_derived_facts(derived, state)
      rescue
        DBConnection.OwnershipError -> state
        Ecto.NoPrimaryKeyValueError -> state
      catch
        :exit, _ -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private

  defp process_derived_facts(derived, state) do
    state =
      derived.stale_nodes
      |> Enum.reduce(state, fn {:node_stale, [node_id]}, acc ->
        handle_stale_node(node_id, acc)
      end)

    state =
      derived.should_fail
      |> Enum.reduce(state, fn {:should_fail, [workload_id]}, acc ->
        handle_should_fail(workload_id, acc)
      end)

    state =
      derived.orphaned
      |> Enum.reduce(state, fn {:workload_orphaned, [workload_id]}, acc ->
        handle_orphaned(workload_id, acc)
      end)

    state =
      derived.can_restart
      |> Enum.reduce(state, fn {:can_restart, [workload_id]}, acc ->
        handle_can_restart(workload_id, acc)
      end)

    Enum.each(derived.overloaded, fn {:node_overloaded, [node_id]} ->
      handle_overloaded(node_id)
    end)

    state
  end

  defp handle_stale_node(node_id, state) do
    if recently_acted?(state, {:stale, node_id}) do
      state
    else
      Logger.warning("Node #{node_id} is stale, marking unavailable")

      Node
      |> Repo.get(node_id)
      |> case do
        nil ->
          state

        node ->
          node
          |> Ecto.Changeset.change(status: "unavailable")
          |> Repo.update()

          broadcast_change(:nodes, :update, node)
          mark_acted(state, {:stale, node_id})
      end
    end
  end

  defp handle_should_fail(workload_id, state) do
    if recently_acted?(state, {:fail, workload_id}) do
      state
    else
      Logger.warning("Workload #{workload_id} should fail (unhealthy node)")

      Workload
      |> Repo.get(workload_id)
      |> case do
        nil ->
          state

        workload ->
          # Try to stop on the agent
          if workload.node_id do
            try_stop_on_agent(workload.node_id, workload_id)
          end

          workload
          |> Ecto.Changeset.change(
            status: "failed",
            error: "Node unhealthy",
            stopped_at: DateTime.utc_now()
          )
          |> Repo.update()

          broadcast_change(:workloads, :update, workload)
          mark_acted(state, {:fail, workload_id})
      end
    end
  end

  defp handle_orphaned(workload_id, state) do
    if recently_acted?(state, {:orphan, workload_id}) do
      state
    else
      Logger.warning("Workload #{workload_id} is orphaned")

      Workload
      |> Repo.get(workload_id)
      |> case do
        nil ->
          state

        workload ->
          workload
          |> Ecto.Changeset.change(
            status: "failed",
            node_id: nil,
            error: "Node no longer exists",
            stopped_at: DateTime.utc_now()
          )
          |> Repo.update()

          broadcast_change(:workloads, :update, workload)
          mark_acted(state, {:orphan, workload_id})
      end
    end
  end

  defp handle_can_restart(workload_id, state) do
    if recently_acted?(state, {:restart, workload_id}) do
      state
    else
      Logger.info("Workload #{workload_id} can be restarted, selecting node")

      candidates = FactStore.placement_candidates(workload_id)

      case select_node(candidates, :spread) do
        {:ok, node_id} ->
          Workload
          |> Repo.get(workload_id)
          |> case do
            nil ->
              state

            workload ->
              case workload
                   |> Ecto.Changeset.change(
                     status: "starting",
                     node_id: node_id,
                     error: nil,
                     stopped_at: nil
                   )
                   |> Repo.update() do
                {:ok, updated} ->
                  broadcast_change(:workloads, :update, updated)

                  # Dispatch to Executor to actually start it
                  try do
                    Dispatcher.dispatch_start(updated)
                  catch
                    :exit, _ -> :ok
                  end

                {:error, _} ->
                  :ok
              end

              mark_acted(state, {:restart, workload_id})
          end

        {:error, :no_candidates} ->
          state
      end
    end
  end

  defp handle_overloaded(node_id) do
    Logger.warning("Node #{node_id} is overloaded (>90% resource usage)")
  end

  defp select_node([], _strategy), do: {:error, :no_candidates}

  defp select_node(candidates, strategy) do
    # candidates are [{:placement_candidate, [workload_id, node_id, cpu_free, mem_free]}]
    case strategy do
      :spread ->
        # Pick node with most free resources
        {_, [_, node_id, _, _]} =
          Enum.max_by(candidates, fn {_, [_, _, cpu, mem]} -> cpu + mem end)

        {:ok, node_id}

      :pack ->
        # Pick node with least free resources
        {_, [_, node_id, _, _]} =
          Enum.min_by(candidates, fn {_, [_, _, cpu, mem]} -> cpu + mem end)

        {:ok, node_id}

      _random ->
        {_, [_, node_id, _, _]} = Enum.random(candidates)
        {:ok, node_id}
    end
  end

  defp try_stop_on_agent(_node_id, workload_id) do
    case Repo.get(Workload, workload_id) do
      nil ->
        :ok

      workload ->
        try do
          Dispatcher.dispatch_stop(workload)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp broadcast_change(schema, action, record) do
    Phoenix.PubSub.broadcast(
      Mxc.PubSub,
      "fact_changes",
      {:fact_change, schema, action, record}
    )
  end

  # Debounce: don't act on the same event more than once per 30 seconds
  defp recently_acted?(state, key) do
    case Map.get(state.last_acted, key) do
      nil -> false
      ts -> System.os_time(:second) - ts < 30
    end
  end

  defp mark_acted(state, key) do
    %{state | last_acted: Map.put(state.last_acted, key, System.os_time(:second))}
  end
end
