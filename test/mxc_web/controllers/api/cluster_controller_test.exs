defmodule MxcWeb.API.ClusterControllerTest do
  use MxcWeb.ConnCase, async: true

  alias Mxc.Coordinator

  describe "GET /api/cluster/status" do
    test "returns cluster status with no data", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/api/cluster/status")
      assert %{"data" => status} = json_response(conn, 200)
      assert status["node_count"] == 0
      assert status["workload_count"] == 0
      assert status["total_cpu"] == 0
    end

    test "returns aggregate status", %{conn: conn} do
      {:ok, _} =
        Coordinator.create_node(%{
          hostname: "n1",
          status: "available",
          cpu_total: 8,
          memory_total: 16384,
          cpu_used: 2,
          memory_used: 4096
        })

      {:ok, _} =
        Coordinator.create_workload(%{type: "process", status: "running", command: "/bin/sleep"})

      conn = conn |> authed() |> get(~p"/api/cluster/status")
      assert %{"data" => status} = json_response(conn, 200)
      assert status["node_count"] == 1
      assert status["workload_count"] == 1
      assert status["workloads_running"] == 1
      assert status["total_cpu"] == 8
      assert status["available_cpu"] == 6
    end
  end
end
