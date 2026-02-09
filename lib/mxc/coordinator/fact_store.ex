defmodule Mxc.Coordinator.FactStore do
  @moduledoc """
  Manages the datalox database instance for rule-based decision making.

  Responsibilities:
  - Creates datalox database on init (ETS-backed)
  - Loads shipped rules from priv/rules/*.dl on startup
  - Loads enabled user rules from scheduling_rules table
  - Bulk-asserts projected facts from Postgres on startup
  - Subscribes to PubSub for real-time fact sync
  - Updates now(Timestamp) fact every 5 seconds
  - Runs diff-based reconciliation every 30 seconds
  - Exposes query API for Reactor and Coordinator context
  """

  use GenServer
  require Logger

  alias Mxc.Coordinator.FactProjection
  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent, SchedulingRule}
  alias Mxc.Repo
  alias Datalox.Parser.Parser

  @tick_interval 5_000
  @reconcile_interval 30_000
  @rules_dir Path.join(:code.priv_dir(:mxc), "rules")
  @shipped_rule_files ["scheduling.dl", "lifecycle.dl", "health.dl"]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queries datalox for facts matching a pattern. Returns deduplicated results.
  """
  def query(pattern) do
    GenServer.call(__MODULE__, {:query, pattern})
  end

  @doc """
  Returns all placement candidates for a workload.
  """
  def placement_candidates(workload_id) do
    query({:placement_candidate, [workload_id, :_, :_, :_]})
  end

  @doc """
  Returns all workloads that should be failed.
  """
  def workloads_to_fail do
    query({:should_fail, [:_]})
  end

  @doc """
  Returns all workloads that can be restarted.
  """
  def workloads_to_restart do
    query({:can_restart, [:_]})
  end

  @doc """
  Returns all stale nodes.
  """
  def stale_nodes do
    query({:node_stale, [:_]})
  end

  @doc """
  Returns all orphaned workloads.
  """
  def orphaned_workloads do
    query({:workload_orphaned, [:_]})
  end

  @doc """
  Returns all overloaded nodes.
  """
  def overloaded_nodes do
    query({:node_overloaded, [:_]})
  end

  @doc """
  Checks if a workload can transition to the given status.
  """
  def can_transition?(workload_id, next_status) do
    results = query({:can_transition, [workload_id, :_]})
    Enum.any?(results, fn {_, [_, status]} -> status == next_status end)
  end

  @doc """
  Forces immediate re-evaluation of all rules against current facts.
  """
  def evaluate do
    GenServer.call(__MODULE__, :evaluate)
  end

  @doc """
  Forces immediate reconciliation with Postgres.
  """
  def reconcile do
    GenServer.call(__MODULE__, :reconcile)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Parse shipped rules at init (combine all .dl files)
    {shipped_facts, shipped_rules} = parse_shipped_rules()

    # Create datalox database
    {:ok, db} = Datalox.new(name: :mxc_fact_store)

    # Assert shipped facts (valid_transition, etc.)
    Datalox.assert_all(db, shipped_facts)

    # Subscribe to fact change events
    Phoenix.PubSub.subscribe(Mxc.PubSub, "fact_changes")

    # Schedule tick and reconciliation
    Process.send_after(self(), :tick, @tick_interval)
    Process.send_after(self(), :reconcile, @reconcile_interval)

    state = %{
      db: db,
      shipped_rules: shipped_rules,
      user_rules: [],
      all_rules: shipped_rules
    }

    # Bulk load from Postgres and evaluate
    state = bulk_load_and_evaluate(state)

    Logger.info("FactStore started with #{length(shipped_rules)} shipped rules")
    {:ok, state}
  end

  @impl true
  def handle_call({:query, pattern}, _from, state) do
    results = Datalox.query(state.db, pattern) |> Enum.uniq()
    {:reply, results, state}
  end

  @impl true
  def handle_call(:evaluate, _from, state) do
    do_evaluate(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    state = do_reconcile(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    # Update now(Timestamp) fact
    now = System.os_time(:second)

    # Retract old now facts and assert new one
    old_nows = Datalox.query(state.db, {:now, [:_]})
    Enum.each(old_nows, fn fact -> Datalox.retract(state.db, fact) end)
    Datalox.assert(state.db, {:now, [now]})

    # Re-evaluate rules with updated time
    do_evaluate(state)

    # Broadcast derived facts for Reactor
    broadcast_derived_facts(state)

    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = do_reconcile(state)
    Process.send_after(self(), :reconcile, @reconcile_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:fact_change, schema, _action, record}, state) do
    # Project the changed record to facts
    new_facts = FactProjection.project(record)

    # Get current facts for this entity to know what to retract
    old_facts = get_entity_facts(state.db, schema, record.id)

    {to_assert, to_retract} = FactProjection.diff(old_facts, new_facts)

    Enum.each(to_retract, fn fact -> Datalox.retract(state.db, fact) end)
    Enum.each(to_assert, fn fact -> Datalox.assert(state.db, fact) end)

    # Re-evaluate rules
    do_evaluate(state)

    # Broadcast derived facts for Reactor
    broadcast_derived_facts(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private

  defp parse_shipped_rules do
    all_statements =
      @shipped_rule_files
      |> Enum.flat_map(fn file ->
        path = Path.join(@rules_dir, file)

        case Parser.parse_file(path) do
          {:ok, stmts} ->
            stmts

          {:error, reason} ->
            Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
            []
        end
      end)

    facts =
      all_statements
      |> Enum.filter(fn {:fact, _} -> true; {:rule, _} -> false end)
      |> Enum.map(fn {:fact, f} -> f end)

    rules =
      all_statements
      |> Enum.filter(fn {:fact, _} -> false; {:rule, _} -> true end)
      |> Enum.map(fn {:rule, r} -> r end)

    {facts, rules}
  end

  defp bulk_load_and_evaluate(state) do
    # Load all entities from Postgres and project to facts
    nodes = Repo.all(Node)
    workloads = Repo.all(Workload)
    events = Repo.all(WorkloadEvent)

    all_facts =
      Enum.flat_map(nodes, &FactProjection.project/1) ++
        Enum.flat_map(workloads, &FactProjection.project/1) ++
        Enum.flat_map(events, &FactProjection.project/1)

    Datalox.assert_all(state.db, all_facts)

    # Assert current time
    Datalox.assert(state.db, {:now, [System.os_time(:second)]})

    # Load user-defined rules
    user_rules = load_user_rules()
    all_rules = state.shipped_rules ++ user_rules

    # Evaluate all rules
    Datalox.Database.load_rules(state.db, all_rules)

    %{state | user_rules: user_rules, all_rules: all_rules}
  end

  defp load_user_rules do
    import Ecto.Query

    SchedulingRule
    |> where([r], r.enabled == true)
    |> order_by([r], r.priority)
    |> Repo.all()
    |> Enum.flat_map(fn rule ->
      case Parser.parse(rule.rule_text) do
        {:ok, stmts} ->
          stmts
          |> Enum.filter(fn {:rule, _} -> true; _ -> false end)
          |> Enum.map(fn {:rule, r} -> r end)

        {:error, reason} ->
          Logger.warning("Invalid user rule '#{rule.name}': #{inspect(reason)}")
          []
      end
    end)
  end

  defp do_evaluate(state) do
    case Datalox.Database.load_rules(state.db, state.all_rules) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Rule evaluation failed: #{inspect(reason)}")
    end
  end

  defp do_reconcile(state) do
    # Reload from Postgres and diff
    nodes = Repo.all(Node)
    workloads = Repo.all(Workload)
    events = Repo.all(WorkloadEvent)

    desired_facts =
      Enum.flat_map(nodes, &FactProjection.project/1) ++
        Enum.flat_map(workloads, &FactProjection.project/1) ++
        Enum.flat_map(events, &FactProjection.project/1)

    # Get current base facts from datalox (exclude derived predicates)
    current_facts = get_all_base_facts(state.db)

    {to_assert, to_retract} = FactProjection.diff(current_facts, desired_facts)

    if to_assert != [] or to_retract != [] do
      Logger.info("Reconciliation: asserting #{length(to_assert)}, retracting #{length(to_retract)}")
      Enum.each(to_retract, fn fact -> Datalox.retract(state.db, fact) end)
      Enum.each(to_assert, fn fact -> Datalox.assert(state.db, fact) end)
      do_evaluate(state)
    end

    # Reload user rules in case they changed
    user_rules = load_user_rules()

    if user_rules != state.user_rules do
      Logger.info("User rules changed, reloading")
      all_rules = state.shipped_rules ++ user_rules
      Datalox.Database.load_rules(state.db, all_rules)
      %{state | user_rules: user_rules, all_rules: all_rules}
    else
      state
    end
  end

  defp get_all_base_facts(db) do
    # Query all base fact predicates (not derived by rules)
    base_predicates = [
      :node,
      :node_resources,
      :node_resources_used,
      :node_resources_free,
      :node_heartbeat,
      :node_capability,
      :workload,
      :workload_placement,
      :workload_resources,
      :workload_constraint,
      :workload_event
    ]

    Enum.flat_map(base_predicates, fn pred ->
      # Use a wildcard pattern based on known arities
      pattern = {pred, wildcard_pattern(pred)}
      Datalox.query(db, pattern)
    end)
  end

  defp wildcard_pattern(:node), do: [:_, :_, :_]
  defp wildcard_pattern(:node_resources), do: [:_, :_, :_]
  defp wildcard_pattern(:node_resources_used), do: [:_, :_, :_]
  defp wildcard_pattern(:node_resources_free), do: [:_, :_, :_]
  defp wildcard_pattern(:node_heartbeat), do: [:_, :_]
  defp wildcard_pattern(:node_capability), do: [:_, :_, :_]
  defp wildcard_pattern(:workload), do: [:_, :_, :_]
  defp wildcard_pattern(:workload_placement), do: [:_, :_]
  defp wildcard_pattern(:workload_resources), do: [:_, :_, :_]
  defp wildcard_pattern(:workload_constraint), do: [:_, :_, :_]
  defp wildcard_pattern(:workload_event), do: [:_, :_, :_]

  defp get_entity_facts(db, :nodes, id) do
    Datalox.query(db, {:node, [id, :_, :_]}) ++
      Datalox.query(db, {:node_resources, [id, :_, :_]}) ++
      Datalox.query(db, {:node_resources_used, [id, :_, :_]}) ++
      Datalox.query(db, {:node_resources_free, [id, :_, :_]}) ++
      Datalox.query(db, {:node_heartbeat, [id, :_]}) ++
      Datalox.query(db, {:node_capability, [id, :_, :_]})
  end

  defp get_entity_facts(db, :workloads, id) do
    Datalox.query(db, {:workload, [id, :_, :_]}) ++
      Datalox.query(db, {:workload_placement, [id, :_]}) ++
      Datalox.query(db, {:workload_resources, [id, :_, :_]}) ++
      Datalox.query(db, {:workload_constraint, [id, :_, :_]})
  end

  defp get_entity_facts(db, :workload_events, id) do
    Datalox.query(db, {:workload_event, [id, :_, :_]})
  end

  defp get_entity_facts(_db, _schema, _id), do: []

  defp broadcast_derived_facts(state) do
    derived = %{
      stale_nodes: Datalox.query(state.db, {:node_stale, [:_]}) |> Enum.uniq(),
      should_fail: Datalox.query(state.db, {:should_fail, [:_]}) |> Enum.uniq(),
      orphaned: Datalox.query(state.db, {:workload_orphaned, [:_]}) |> Enum.uniq(),
      can_restart: Datalox.query(state.db, {:can_restart, [:_]}) |> Enum.uniq(),
      overloaded: Datalox.query(state.db, {:node_overloaded, [:_]}) |> Enum.uniq()
    }

    Phoenix.PubSub.broadcast(Mxc.PubSub, "derived_facts", {:derived_facts, derived})
  end
end
