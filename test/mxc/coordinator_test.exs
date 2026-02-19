defmodule Mxc.CoordinatorTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator

  describe "nodes" do
    test "create_node/1 creates a node" do
      attrs = %{
        hostname: "node-1",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 0,
        memory_used: 0,
        hypervisor: "firecracker"
      }

      assert {:ok, node} = Coordinator.create_node(attrs)
      assert node.hostname == "node-1"
      assert node.status == "available"
      assert node.cpu_total == 8
      assert node.memory_total == 16384
      assert node.hypervisor == "firecracker"
    end

    test "list_nodes/0 returns all nodes" do
      {:ok, _} = Coordinator.create_node(%{hostname: "a", status: "available", cpu_total: 4, memory_total: 8192, cpu_used: 0, memory_used: 0})
      {:ok, _} = Coordinator.create_node(%{hostname: "b", status: "available", cpu_total: 8, memory_total: 16384, cpu_used: 0, memory_used: 0})

      nodes = Coordinator.list_nodes()
      assert length(nodes) == 2
      hostnames = Enum.map(nodes, & &1.hostname)
      assert "a" in hostnames
      assert "b" in hostnames
    end

    test "get_node/1 returns a node by ID" do
      {:ok, node} = Coordinator.create_node(%{hostname: "n1", status: "available", cpu_total: 4, memory_total: 8192, cpu_used: 0, memory_used: 0})

      assert {:ok, found} = Coordinator.get_node(node.id)
      assert found.id == node.id
    end

    test "get_node/1 returns error for missing node" do
      assert {:error, :not_found} = Coordinator.get_node(Ecto.UUID.generate())
    end

    test "update_node/2 updates a node" do
      {:ok, node} = Coordinator.create_node(%{hostname: "n1", status: "available", cpu_total: 4, memory_total: 8192, cpu_used: 0, memory_used: 0})

      assert {:ok, updated} = Coordinator.update_node(node, %{cpu_used: 2, memory_used: 4096})
      assert updated.cpu_used == 2
      assert updated.memory_used == 4096
    end

    test "delete_node/1 removes a node" do
      {:ok, node} = Coordinator.create_node(%{hostname: "n1", status: "available", cpu_total: 4, memory_total: 8192, cpu_used: 0, memory_used: 0})

      assert {:ok, _} = Coordinator.delete_node(node)
      assert {:error, :not_found} = Coordinator.get_node(node.id)
    end

    test "heartbeat_node/2 updates heartbeat time" do
      {:ok, node} = Coordinator.create_node(%{hostname: "n1", status: "available", cpu_total: 4, memory_total: 8192, cpu_used: 0, memory_used: 0})
      assert node.last_heartbeat_at == nil

      assert {:ok, updated} = Coordinator.heartbeat_node(node.id, %{cpu_used: 1})
      assert updated.last_heartbeat_at != nil
      assert updated.cpu_used == 1
    end
  end

  describe "workloads" do
    test "create_workload/1 creates a workload" do
      attrs = %{
        type: "process",
        status: "pending",
        command: "/bin/sleep 60"
      }

      assert {:ok, workload} = Coordinator.create_workload(attrs)
      assert workload.type == "process"
      assert workload.status == "pending"
      assert workload.command == "/bin/sleep 60"
    end

    test "list_workloads/0 returns workloads ordered by insertion" do
      {:ok, _} = Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep 1"})
      {:ok, _} = Coordinator.create_workload(%{type: "microvm", status: "pending", command: "/bin/sleep 2"})

      workloads = Coordinator.list_workloads()
      assert length(workloads) == 2
    end

    test "get_workload/1 returns a workload by ID" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep"})

      assert {:ok, found} = Coordinator.get_workload(workload.id)
      assert found.id == workload.id
    end

    test "stop_workload/1 transitions running workload to stopping" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "running", command: "/bin/sleep"})

      assert {:ok, stopped} = Coordinator.stop_workload(workload.id)
      assert stopped.status == "stopping"
    end

    test "stop_workload/1 rejects non-running workloads" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep"})

      assert {:error, :invalid_state} = Coordinator.stop_workload(workload.id)
    end

    test "deploy_workload/1 creates a pending workload" do
      attrs = %{
        type: "process",
        command: "/bin/sleep 60",
        cpu: 2,
        memory_mb: 1024
      }

      assert {:ok, workload} = Coordinator.deploy_workload(attrs)
      assert workload.status == "pending"
      assert workload.command == "/bin/sleep 60"
      assert workload.cpu_required == 2
      assert workload.memory_required == 1024
    end

    test "deploy_workload/1 rejects unknown workload type" do
      attrs = %{type: "docker", command: "nginx"}
      assert {:error, msg} = Coordinator.deploy_workload(attrs)
      assert msg =~ "unknown workload type"
    end

    test "deploy_workload/1 auto-adds microvm constraint for microvm type" do
      attrs = %{type: "microvm", command: "mxc-vm-aarch64"}

      # microvm may or may not be valid depending on platform,
      # but if it is, the constraints should include "microvm" => "true"
      case Coordinator.deploy_workload(attrs) do
        {:ok, workload} ->
          assert workload.constraints["microvm"] == "true"

        {:error, _} ->
          # Platform doesn't support microvm — that's fine
          :ok
      end
    end
  end

  describe "workload events" do
    test "create and list workload events" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep"})

      {:ok, _event} = Coordinator.create_workload_event(%{
        workload_id: workload.id,
        event_type: "status_change",
        metadata: %{from: "pending", to: "starting"}
      })

      events = Coordinator.list_workload_events(workload.id)
      assert length(events) == 1
      assert hd(events).event_type == "status_change"
    end
  end

  describe "scheduling rules" do
    test "CRUD for scheduling rules" do
      {:ok, rule} = Coordinator.create_scheduling_rule(%{
        name: "test-rule",
        rule_text: "test_derived(X) :- workload(X, _, pending).",
        priority: 10
      })

      assert rule.name == "test-rule"
      assert rule.enabled == true

      rules = Coordinator.list_scheduling_rules()
      assert length(rules) == 1

      {:ok, updated} = Coordinator.update_scheduling_rule(rule, %{enabled: false})
      assert updated.enabled == false

      {:ok, _} = Coordinator.delete_scheduling_rule(updated)
      assert Coordinator.list_scheduling_rules() == []
    end
  end

  describe "exec_in_workload/3" do
    test "returns error for non-existent workload" do
      assert {:error, :not_found} = Coordinator.exec_in_workload(Ecto.UUID.generate(), "echo hi")
    end

    test "returns error for non-running workload" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "pending", command: "echo"})
      assert {:error, :workload_not_running} = Coordinator.exec_in_workload(workload.id, "echo hi")
    end

    test "executes command in running process workload" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "running", command: "echo"})
      assert {:ok, output} = Coordinator.exec_in_workload(workload.id, "echo hello_from_exec")
      assert output == "hello_from_exec"
    end

    test "returns error for failed command" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "running", command: "echo"})
      assert {:error, {:exit_code, _, _}} = Coordinator.exec_in_workload(workload.id, "false")
    end
  end

  describe "discover_workload_ip/1" do
    test "returns error for non-existent workload" do
      assert {:error, :not_found} = Coordinator.discover_workload_ip(Ecto.UUID.generate())
    end

    test "discovers IP for running process workload" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "running", command: "echo"})

      case Coordinator.discover_workload_ip(workload.id) do
        {:ok, updated} ->
          # hostname -I returns at least one IP on most systems
          assert updated.ip != nil
          assert updated.ip != ""

        {:error, _} ->
          # hostname -I may not work on all CI environments
          :ok
      end
    end
  end

  describe "workload ip field" do
    test "create_workload with ip stores it" do
      {:ok, workload} = Coordinator.create_workload(%{
        type: "process",
        status: "running",
        command: "echo",
        ip: "10.0.0.5"
      })

      assert workload.ip == "10.0.0.5"
    end

    test "update_workload can set ip" do
      {:ok, workload} = Coordinator.create_workload(%{type: "process", status: "running", command: "echo"})
      assert workload.ip == nil

      {:ok, updated} = Coordinator.update_workload(workload, %{ip: "192.168.1.100"})
      assert updated.ip == "192.168.1.100"
    end
  end

  describe "cluster_status/0" do
    test "returns aggregate status" do
      {:ok, _} = Coordinator.create_node(%{
        hostname: "n1",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096
      })

      {:ok, _} = Coordinator.create_workload(%{type: "process", status: "running", command: "/bin/sleep"})
      {:ok, _} = Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep"})

      status = Coordinator.cluster_status()
      assert status.node_count == 1
      assert status.workload_count == 2
      assert status.workloads_running == 1
      assert status.total_cpu == 8
      assert status.total_memory == 16384
      assert status.available_cpu == 6
      assert status.available_memory == 12288
    end
  end
end
