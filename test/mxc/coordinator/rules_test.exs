defmodule Mxc.Coordinator.RulesTest do
  use ExUnit.Case, async: true

  alias Datalox.Parser.Parser

  @rules_dir Path.join(:code.priv_dir(:mxc), "rules")

  # Parse all .dl files and combine facts + rules into single lists.
  # This works around datalox bug #4: load_rules replaces instead of appending.
  @all_statements (
    ["scheduling.dl", "lifecycle.dl", "health.dl"]
    |> Enum.flat_map(fn file ->
      {:ok, stmts} = Parser.parse_file(Path.join(@rules_dir, file))
      stmts
    end)
  )

  @all_facts @all_statements
             |> Enum.filter(fn {:fact, _} -> true; {:rule, _} -> false end)
             |> Enum.map(fn {:fact, f} -> f end)

  @all_rules @all_statements
             |> Enum.filter(fn {:fact, _} -> false; {:rule, _} -> true end)
             |> Enum.map(fn {:rule, r} -> r end)

  setup do
    db_name = :"rules_test_#{:erlang.unique_integer([:positive])}"
    {:ok, db} = Datalox.new(name: db_name)

    # Assert .dl file facts (e.g. valid_transition) first
    Datalox.assert_all(db, @all_facts)

    %{db: db}
  end

  # Loads all rules, triggering evaluation against current facts.
  # Must be called AFTER asserting test-specific facts (datalox bug #3).
  defp evaluate!(db) do
    :ok = Datalox.Database.load_rules(db, @all_rules)
  end

  describe "scheduling rules" do
    test "node_healthy derived when node is available and heartbeat recent", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 10]})
      Datalox.assert(db, {:now, [now]})
      evaluate!(db)

      results = Datalox.query(db, {:node_healthy, [:_]}) |> Enum.uniq()
      assert results == [{:node_healthy, ["n1"]}]
    end

    test "node_healthy not derived when heartbeat is stale", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 60]})
      Datalox.assert(db, {:now, [now]})
      evaluate!(db)

      results = Datalox.query(db, {:node_healthy, [:_]})
      assert results == []
    end

    test "node_resources_free is an asserted fact (pre-computed)", %{db: db} do
      # node_resources_free is asserted by FactProjection, not derived by rules
      Datalox.assert(db, {:node_resources_free, ["n1", 5, 12288]})

      results = Datalox.query(db, {:node_resources_free, ["n1", :_, :_]})
      assert {:node_resources_free, ["n1", 5, 12288]} in results
    end

    test "can_place derives when workload fits on healthy node", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 5]})
      Datalox.assert(db, {:node_resources, ["n1", 8, 16384]})
      Datalox.assert(db, {:node_resources_used, ["n1", 2, 4096]})
      Datalox.assert(db, {:node_resources_free, ["n1", 6, 12288]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :process, :pending]})
      Datalox.assert(db, {:workload_resources, ["w1", 2, 2048]})
      evaluate!(db)

      results = Datalox.query(db, {:can_place, ["w1", :_]})
      assert {:can_place, ["w1", "n1"]} in results
    end

    test "can_place not derived when node lacks capacity", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 5]})
      Datalox.assert(db, {:node_resources, ["n1", 4, 8192]})
      Datalox.assert(db, {:node_resources_used, ["n1", 3, 7000]})
      Datalox.assert(db, {:node_resources_free, ["n1", 1, 1192]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :process, :pending]})
      Datalox.assert(db, {:workload_resources, ["w1", 4, 4096]})
      evaluate!(db)

      results = Datalox.query(db, {:can_place, ["w1", :_]})
      assert results == []
    end

    test "constraint_violated blocks placement when capability missing", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 5]})
      Datalox.assert(db, {:node_resources, ["n1", 8, 16384]})
      Datalox.assert(db, {:node_resources_used, ["n1", 0, 0]})
      Datalox.assert(db, {:node_resources_free, ["n1", 8, 16384]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :microvm, :pending]})
      Datalox.assert(db, {:workload_resources, ["w1", 2, 2048]})
      Datalox.assert(db, {:workload_constraint, ["w1", :gpu, :nvidia]})
      evaluate!(db)

      results = Datalox.query(db, {:can_place, ["w1", :_]})
      assert results == []

      violated = Datalox.query(db, {:constraint_violated, ["w1", :_]})
      assert {:constraint_violated, ["w1", "n1"]} in violated
    end

    test "placement_candidate includes free resources", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 5]})
      Datalox.assert(db, {:node_resources, ["n1", 8, 16384]})
      Datalox.assert(db, {:node_resources_used, ["n1", 2, 4096]})
      Datalox.assert(db, {:node_resources_free, ["n1", 6, 12288]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :process, :pending]})
      Datalox.assert(db, {:workload_resources, ["w1", 1, 1024]})
      evaluate!(db)

      results = Datalox.query(db, {:placement_candidate, ["w1", :_, :_, :_]})
      assert {:placement_candidate, ["w1", "n1", 6, 12288]} in results
    end
  end

  describe "lifecycle rules" do
    test "valid_transition facts are loaded", %{db: db} do
      results = Datalox.query(db, {:valid_transition, [:_, :_]})
      assert length(results) == 6
      assert {:valid_transition, [:pending, :starting]} in results
      assert {:valid_transition, [:running, :failed]} in results
    end

    test "can_transition derived for workload in valid state", %{db: db} do
      Datalox.assert(db, {:workload, ["w1", :process, :pending]})
      evaluate!(db)

      results = Datalox.query(db, {:can_transition, ["w1", :_]})
      assert {:can_transition, ["w1", :starting]} in results
    end

    test "should_fail derived when workload's node is unhealthy", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 60]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :process, :running]})
      Datalox.assert(db, {:workload_placement, ["w1", "n1"]})
      evaluate!(db)

      results = Datalox.query(db, {:should_fail, [:_]})
      assert {:should_fail, ["w1"]} in results
    end

    test "can_restart derived when failed workload has viable node", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 5]})
      Datalox.assert(db, {:node_resources, ["n1", 8, 16384]})
      Datalox.assert(db, {:node_resources_used, ["n1", 0, 0]})
      Datalox.assert(db, {:node_resources_free, ["n1", 8, 16384]})
      Datalox.assert(db, {:now, [now]})

      Datalox.assert(db, {:workload, ["w1", :process, :failed]})
      Datalox.assert(db, {:workload_resources, ["w1", 2, 2048]})
      evaluate!(db)

      results = Datalox.query(db, {:can_restart, [:_]})
      assert {:can_restart, ["w1"]} in results
    end
  end

  describe "health rules" do
    test "node_stale derived when heartbeat is old", %{db: db} do
      now = System.os_time(:second)

      Datalox.assert(db, {:node, ["n1", "host1", :available]})
      Datalox.assert(db, {:node_heartbeat, ["n1", now - 45]})
      Datalox.assert(db, {:now, [now]})
      evaluate!(db)

      results = Datalox.query(db, {:node_stale, [:_]})
      assert {:node_stale, ["n1"]} in results
    end

    test "node_overloaded derived when CPU usage exceeds 90%", %{db: db} do
      Datalox.assert(db, {:node_resources, ["n1", 100, 16384]})
      Datalox.assert(db, {:node_resources_used, ["n1", 95, 8000]})
      evaluate!(db)

      results = Datalox.query(db, {:node_overloaded, [:_]})
      assert {:node_overloaded, ["n1"]} in results
    end

    test "node_overloaded derived when memory usage exceeds 90%", %{db: db} do
      Datalox.assert(db, {:node_resources, ["n1", 100, 10000]})
      Datalox.assert(db, {:node_resources_used, ["n1", 10, 9500]})
      evaluate!(db)

      results = Datalox.query(db, {:node_overloaded, [:_]})
      assert {:node_overloaded, ["n1"]} in results
    end

    test "node_overloaded not derived when usage is below 90%", %{db: db} do
      Datalox.assert(db, {:node_resources, ["n1", 100, 10000]})
      Datalox.assert(db, {:node_resources_used, ["n1", 50, 5000]})
      evaluate!(db)

      results = Datalox.query(db, {:node_overloaded, [:_]})
      assert results == []
    end

    test "workload_orphaned derived when node doesn't exist", %{db: db} do
      Datalox.assert(db, {:workload, ["w1", :process, :running]})
      Datalox.assert(db, {:workload_placement, ["w1", "ghost_node"]})
      evaluate!(db)

      results = Datalox.query(db, {:workload_orphaned, [:_]})
      assert {:workload_orphaned, ["w1"]} in results
    end
  end
end
