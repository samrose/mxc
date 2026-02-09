defmodule MxcWeb.WorkloadsLiveTest do
  use MxcWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mxc.Coordinator

  setup do
    {:ok, workload} =
      Coordinator.create_workload(%{
        type: "process",
        status: "running",
        command: "/bin/sleep 60",
        cpu_required: 2,
        memory_required: 1024
      })

    %{workload: workload}
  end

  test "renders workloads list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workloads")
    assert html =~ "Workloads"
    assert html =~ "process"
    assert html =~ "running"
  end

  test "shows empty state with no workloads", %{conn: conn, workload: workload} do
    Mxc.Repo.delete(workload)
    {:ok, _view, html} = live(conn, ~p"/workloads")
    assert html =~ "No workloads deployed"
  end

  test "clicking a workload shows details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")

    html =
      view
      |> element("tr[phx-click=select_workload]")
      |> render_click()

    assert html =~ "Workload Details"
    assert html =~ "/bin/sleep 60"
    assert html =~ "2 CPU, 1024 MB"
  end

  test "navigating to workload by id shows details", %{conn: conn, workload: workload} do
    {:ok, _view, html} = live(conn, ~p"/workloads/#{workload.id}")
    assert html =~ "Workload Details"
    assert html =~ "/bin/sleep 60"
  end

  test "navigating to missing workload redirects", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/workloads"}}} =
             live(conn, ~p"/workloads/#{Ecto.UUID.generate()}")
  end

  test "shows deploy modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")

    html =
      view
      |> element("button", "Deploy Workload")
      |> render_click()

    assert html =~ "Deploy Workload"
    assert html =~ "Command"
    assert html =~ "CPU Cores"
    assert html =~ "Memory (MB)"
  end

  test "hides deploy modal on cancel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")

    view |> element("button", "Deploy Workload") |> render_click()

    html =
      view
      |> element("button", "Cancel")
      |> render_click()

    refute html =~ "modal-open"
  end

  test "deploys a workload from modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")

    view |> element("button", "Deploy Workload") |> render_click()

    view
    |> form("form", %{
      "type" => "process",
      "command" => "/bin/echo test",
      "cpu" => "1",
      "memory_mb" => "256"
    })
    |> render_submit()

    # After deploy, the new workload should appear in the list
    html = render(view)
    assert html =~ "/bin/echo test"
    assert html =~ "pending"
  end

  test "stop button appears for running workloads", %{conn: conn, workload: workload} do
    {:ok, _view, html} = live(conn, ~p"/workloads/#{workload.id}")
    assert html =~ "Stop"
  end

  test "stopping a workload updates status", %{conn: conn, workload: workload} do
    {:ok, view, _html} = live(conn, ~p"/workloads/#{workload.id}")

    html =
      view
      |> element("button", "Stop")
      |> render_click()

    assert html =~ "stopping"
  end
end
