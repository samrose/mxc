defmodule MxcWeb.API.WorkloadControllerTest do
  use MxcWeb.ConnCase, async: true

  alias Mxc.Coordinator

  setup do
    {:ok, workload} =
      Coordinator.create_workload(%{
        type: "process",
        status: "running",
        command: "/bin/sleep 60"
      })

    %{workload: workload}
  end

  describe "GET /api/workloads" do
    test "returns list of workloads", %{conn: conn, workload: workload} do
      conn = conn |> authed() |> get(~p"/api/workloads")
      assert %{"data" => workloads} = json_response(conn, 200)
      assert length(workloads) == 1
      assert hd(workloads)["id"] == workload.id
    end
  end

  describe "GET /api/workloads/:id" do
    test "returns a workload by id", %{conn: conn, workload: workload} do
      conn = conn |> authed() |> get(~p"/api/workloads/#{workload.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == workload.id
      assert data["type"] == "process"
      assert data["command"] == "/bin/sleep 60"
    end

    test "returns 404 for missing workload", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/api/workloads/#{Ecto.UUID.generate()}")
      assert %{"error" => "Workload not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/workloads" do
    test "creates a workload", %{conn: conn} do
      params = %{
        "type" => "process",
        "command" => "/bin/echo hello",
        "cpu" => 2,
        "memory_mb" => 512
      }

      conn = conn |> authed() |> post(~p"/api/workloads", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["type"] == "process"
      assert data["command"] == "/bin/echo hello"
      assert data["status"] == "pending"
    end

    test "returns error for missing command", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/workloads", %{"type" => "process"})
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["command"]
    end
  end

  describe "POST /api/workloads/:id/stop" do
    test "stops a running workload", %{conn: conn, workload: workload} do
      conn = conn |> authed() |> post(~p"/api/workloads/#{workload.id}/stop")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "stopping"
    end

    test "returns 404 for missing workload", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/workloads/#{Ecto.UUID.generate()}/stop")
      assert %{"error" => "Workload not found"} = json_response(conn, 404)
    end

    test "returns error for non-stoppable workload", %{conn: conn} do
      {:ok, pending} =
        Coordinator.create_workload(%{type: "process", status: "pending", command: "/bin/sleep"})

      conn = conn |> authed() |> post(~p"/api/workloads/#{pending.id}/stop")
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/workloads/:id" do
    test "deletes a workload", %{conn: conn, workload: workload} do
      conn = conn |> authed() |> delete(~p"/api/workloads/#{workload.id}")
      assert response(conn, 204)

      conn = build_conn() |> authed() |> get(~p"/api/workloads/#{workload.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for missing workload", %{conn: conn} do
      conn = conn |> authed() |> delete(~p"/api/workloads/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end
end
