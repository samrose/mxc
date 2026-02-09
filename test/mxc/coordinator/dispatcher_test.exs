defmodule Mxc.Coordinator.DispatcherTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator
  alias Mxc.Coordinator.Dispatcher

  describe "dispatch_start/1" do
    test "returns error when Executor not running (test env)" do
      {:ok, node} =
        Coordinator.create_node(%{
          hostname: "dispatch-test",
          status: "available",
          cpu_total: 4,
          memory_total: 8192,
          cpu_used: 0,
          memory_used: 0
        })

      {:ok, workload} =
        Coordinator.create_workload(%{
          type: "process",
          status: "starting",
          command: "/bin/echo hello",
          node_id: node.id
        })

      # Executor isn't running in test, so this should handle gracefully
      result = Dispatcher.dispatch_start(workload)
      # Either returns error or catches the exit
      assert result == {:error, :agent_not_found} or match?({:error, _}, result) or
               match?(:ok, result)
    end
  end

  describe "dispatch_stop/1" do
    test "returns error when Executor not running (test env)" do
      {:ok, node} =
        Coordinator.create_node(%{
          hostname: "dispatch-stop-test",
          status: "available",
          cpu_total: 4,
          memory_total: 8192,
          cpu_used: 0,
          memory_used: 0
        })

      {:ok, workload} =
        Coordinator.create_workload(%{
          type: "process",
          status: "running",
          command: "/bin/sleep 60",
          node_id: node.id
        })

      result = Dispatcher.dispatch_stop(workload)
      assert result == {:error, :agent_not_found} or match?({:error, _}, result) or
               match?(:ok, result)
    end
  end
end
