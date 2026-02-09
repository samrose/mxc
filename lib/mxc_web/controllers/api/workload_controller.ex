defmodule MxcWeb.API.WorkloadController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    workloads = Coordinator.list_workloads()
    json(conn, %{data: workloads})
  end

  def show(conn, %{"id" => workload_id}) do
    case Coordinator.get_workload(workload_id) do
      {:ok, workload} ->
        json(conn, %{data: workload})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workload not found"})
    end
  end

  def create(conn, params) do
    case Coordinator.deploy_workload(params) do
      {:ok, workload} ->
        conn
        |> put_status(:created)
        |> json(%{data: workload})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"id" => workload_id}) do
    case Coordinator.stop_workload(workload_id) do
      {:ok, workload} ->
        json(conn, %{data: workload})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workload not found"})

      {:error, :invalid_state} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Workload is not in a stoppable state"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => workload_id}) do
    case Coordinator.get_workload(workload_id) do
      {:ok, workload} ->
        Mxc.Repo.delete(workload)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workload not found"})
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
