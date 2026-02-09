defmodule Mxc.Coordinator.FactProjectionTest do
  use ExUnit.Case, async: true

  alias Mxc.Coordinator.FactProjection
  alias Mxc.Coordinator.Schemas.{Node, Workload}

  describe "project/1 for Node" do
    test "projects node into normalized facts" do
      node = %Node{
        id: "node-1",
        hostname: "agent1.local",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096,
        hypervisor: "qemu",
        capabilities: %{"gpu" => "a100", "storage" => "ssd"},
        last_heartbeat_at: ~U[2026-02-08 12:00:00Z]
      }

      facts = FactProjection.project(node)

      assert {:node, ["node-1", "agent1.local", :available]} in facts
      assert {:node_resources, ["node-1", 8, 16384]} in facts
      assert {:node_resources_used, ["node-1", 2, 4096]} in facts
      assert {:node_resources_free, ["node-1", 6, 12288]} in facts
      assert Enum.any?(facts, fn
        {:node_heartbeat, ["node-1", _ts]} -> true
        _ -> false
      end)
      assert {:node_capability, ["node-1", "gpu", "a100"]} in facts
      assert {:node_capability, ["node-1", "storage", "ssd"]} in facts
      assert {:node_capability, ["node-1", :hypervisor, :qemu]} in facts
    end

    test "projects node without capabilities or hypervisor" do
      node = %Node{
        id: "node-2",
        hostname: "agent2.local",
        status: "unavailable",
        cpu_total: 4,
        memory_total: 8192,
        cpu_used: 0,
        memory_used: 0,
        hypervisor: nil,
        capabilities: %{},
        last_heartbeat_at: ~U[2026-02-08 12:00:00Z]
      }

      facts = FactProjection.project(node)
      refute Enum.any?(facts, fn
        {:node_capability, _} -> true
        _ -> false
      end)
    end
  end

  describe "project/1 for Workload" do
    test "projects workload with placement and constraints" do
      workload = %Workload{
        id: "wl-1",
        type: "process",
        status: "running",
        node_id: "node-1",
        cpu_required: 2,
        memory_required: 512,
        constraints: %{"hypervisor" => "qemu"}
      }

      facts = FactProjection.project(workload)

      assert {:workload, ["wl-1", :process, :running]} in facts
      assert {:workload_placement, ["wl-1", "node-1"]} in facts
      assert {:workload_resources, ["wl-1", 2, 512]} in facts
      assert {:workload_constraint, ["wl-1", "hypervisor", "qemu"]} in facts
    end

    test "projects pending workload without placement" do
      workload = %Workload{
        id: "wl-2",
        type: "microvm",
        status: "pending",
        node_id: nil,
        cpu_required: 1,
        memory_required: 256,
        constraints: %{}
      }

      facts = FactProjection.project(workload)

      assert {:workload, ["wl-2", :microvm, :pending]} in facts
      refute Enum.any?(facts, fn
        {:workload_placement, _} -> true
        _ -> false
      end)
    end
  end

  describe "diff/2" do
    test "returns facts to assert and retract" do
      current = [
        {:node, ["n1", "host1", :available]},
        {:node, ["n2", "host2", :available]}
      ]

      desired = [
        {:node, ["n1", "host1", :available]},
        {:node, ["n3", "host3", :available]}
      ]

      {to_assert, to_retract} = FactProjection.diff(current, desired)

      assert {:node, ["n3", "host3", :available]} in to_assert
      assert {:node, ["n2", "host2", :available]} in to_retract
      refute {:node, ["n1", "host1", :available]} in to_assert
    end

    test "returns empty when identical" do
      facts = [{:node, ["n1", "host1", :available]}]
      {to_assert, to_retract} = FactProjection.diff(facts, facts)
      assert to_assert == []
      assert to_retract == []
    end
  end
end
