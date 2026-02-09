defmodule MxcWeb.NodesLiveTest do
  use MxcWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mxc.Coordinator

  setup do
    {:ok, node} =
      Coordinator.create_node(%{
        hostname: "test-node-1",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096,
        hypervisor: "firecracker"
      })

    %{node: node}
  end

  test "renders nodes list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/nodes")
    assert html =~ "Nodes"
    assert html =~ "test-node-1"
    assert html =~ "available"
    assert html =~ "firecracker"
  end

  test "shows empty state with no nodes", %{conn: conn, node: node} do
    Coordinator.delete_node(node)
    {:ok, _view, html} = live(conn, ~p"/nodes")
    assert html =~ "No nodes registered"
  end

  test "clicking a node shows details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/nodes")

    html =
      view
      |> element("tr[phx-click=select_node]")
      |> render_click()

    assert html =~ "Node Details"
    assert html =~ "test-node-1"
    assert html =~ "firecracker"
  end

  test "navigating to node by id shows details", %{conn: conn, node: node} do
    {:ok, _view, html} = live(conn, ~p"/nodes/#{node.id}")
    assert html =~ "Node Details"
    assert html =~ "test-node-1"
  end

  test "navigating to missing node redirects", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/nodes"}}} =
             live(conn, ~p"/nodes/#{Ecto.UUID.generate()}")
  end
end
