defmodule MxcWeb.API.WorkloadController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    workloads = Coordinator.list_workloads()
    json(conn, workloads)
  end

  def show(conn, %{"id" => workload_id}) do
    case Coordinator.get_workload(workload_id) do
      {:ok, workload} ->
        json(conn, workload)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workload not found"})
    end
  end

  def create(conn, params) do
    spec = %{
      type: String.to_atom(params["type"] || "process"),
      command: params["command"],
      args: params["args"] || [],
      env: params["env"] || %{},
      cpu: params["cpu"] || 1,
      memory_mb: params["memory_mb"] || 256,
      cwd: params["cwd"],
      # MicroVM specific
      kernel: params["kernel"],
      initrd: params["initrd"],
      cmdline: params["cmdline"],
      vcpus: params["vcpus"],
      disk: params["disk"],
      tap_device: params["tap_device"]
    }

    case Coordinator.deploy_workload(spec) do
      {:ok, workload} ->
        conn
        |> put_status(:created)
        |> json(workload)

      {:error, :no_nodes} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "No nodes available"})

      {:error, :no_capacity} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "No nodes with sufficient capacity"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"id" => workload_id}) do
    case Coordinator.stop_workload(workload_id) do
      :ok ->
        json(conn, %{status: "stopping"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workload not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end
end
