defmodule MxcWeb.DashboardLiveTest do
  use MxcWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mxc.Coordinator

  test "renders dashboard with empty cluster", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Cluster Dashboard"
    assert html =~ "No nodes connected"
    assert html =~ "No workloads"
  end

  test "displays node data", %{conn: conn} do
    {:ok, _} =
      Coordinator.create_node(%{
        hostname: "web-1",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096
      })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "web-1"
    assert html =~ "available"
  end

  test "displays workload data", %{conn: conn} do
    {:ok, _} =
      Coordinator.create_workload(%{
        type: "process",
        status: "running",
        command: "/bin/sleep 60"
      })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "process"
    assert html =~ "running"
  end

  test "displays cluster stats", %{conn: conn} do
    {:ok, _} =
      Coordinator.create_node(%{
        hostname: "n1",
        status: "available",
        cpu_total: 4,
        memory_total: 8192,
        cpu_used: 1,
        memory_used: 2048
      })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "1"  # node count
    assert html =~ "3/4"  # available/total cpu
  end
end
