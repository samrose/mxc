defmodule MxcWeb.API.NodeControllerTest do
  use MxcWeb.ConnCase, async: true

  alias Mxc.Coordinator

  setup do
    {:ok, node} =
      Coordinator.create_node(%{
        hostname: "test-node",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096
      })

    %{node: node}
  end

  describe "GET /api/nodes" do
    test "returns list of nodes", %{conn: conn, node: node} do
      conn = conn |> authed() |> get(~p"/api/nodes")
      assert %{"data" => nodes} = json_response(conn, 200)
      assert length(nodes) == 1
      assert hd(nodes)["hostname"] == node.hostname
    end

    test "returns empty list when no nodes", %{conn: conn, node: node} do
      Coordinator.delete_node(node)
      conn = conn |> authed() |> get(~p"/api/nodes")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/nodes/:id" do
    test "returns a node by id", %{conn: conn, node: node} do
      conn = conn |> authed() |> get(~p"/api/nodes/#{node.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == node.id
      assert data["hostname"] == "test-node"
      assert data["cpu_total"] == 8
    end

    test "returns 404 for missing node", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/api/nodes/#{Ecto.UUID.generate()}")
      assert %{"error" => "Node not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/nodes" do
    test "creates a node", %{conn: conn} do
      params = %{
        "hostname" => "new-node",
        "status" => "available",
        "cpu_total" => 4,
        "memory_total" => 8192,
        "cpu_used" => 0,
        "memory_used" => 0,
        "hypervisor" => "firecracker"
      }

      conn = conn |> authed() |> post(~p"/api/nodes", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["hostname"] == "new-node"
      assert data["hypervisor"] == "firecracker"
      assert data["cpu_total"] == 4
    end

    test "returns error for missing required fields", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/nodes", %{"hypervisor" => "kvm"})
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["hostname"]
    end

    test "returns error for invalid status", %{conn: conn} do
      params = %{
        "hostname" => "bad-node",
        "status" => "bogus",
        "cpu_total" => 4,
        "memory_total" => 8192,
        "cpu_used" => 0,
        "memory_used" => 0
      }

      conn = conn |> authed() |> post(~p"/api/nodes", params)
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["status"]
    end

    test "returns error for duplicate hostname", %{conn: conn} do
      params = %{
        "hostname" => "test-node",
        "status" => "available",
        "cpu_total" => 4,
        "memory_total" => 8192,
        "cpu_used" => 0,
        "memory_used" => 0
      }

      conn = conn |> authed() |> post(~p"/api/nodes", params)
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["hostname"]
    end
  end

  describe "PUT /api/nodes/:id" do
    test "updates a node", %{conn: conn, node: node} do
      conn = conn |> authed() |> put(~p"/api/nodes/#{node.id}", %{"cpu_used" => 6})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["cpu_used"] == 6
      assert data["hostname"] == "test-node"
    end

    test "returns 404 for missing node", %{conn: conn} do
      conn = conn |> authed() |> put(~p"/api/nodes/#{Ecto.UUID.generate()}", %{"cpu_used" => 1})
      assert %{"error" => "Node not found"} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/nodes/:id" do
    test "deletes a node", %{conn: conn, node: node} do
      conn = conn |> authed() |> delete(~p"/api/nodes/#{node.id}")
      assert response(conn, 204)

      conn = build_conn() |> authed() |> get(~p"/api/nodes/#{node.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for missing node", %{conn: conn} do
      conn = conn |> authed() |> delete(~p"/api/nodes/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end
end
