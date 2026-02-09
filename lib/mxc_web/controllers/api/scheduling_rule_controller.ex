defmodule MxcWeb.API.SchedulingRuleController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    rules = Coordinator.list_scheduling_rules()
    json(conn, %{data: rules})
  end

  def show(conn, %{"id" => id}) do
    case Coordinator.get_scheduling_rule(id) do
      {:ok, rule} ->
        json(conn, %{data: rule})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scheduling rule not found"})
    end
  end

  def create(conn, params) do
    case Coordinator.create_scheduling_rule(params) do
      {:ok, rule} ->
        conn
        |> put_status(:created)
        |> json(%{data: rule})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, rule} <- Coordinator.get_scheduling_rule(id),
         {:ok, updated} <- Coordinator.update_scheduling_rule(rule, Map.delete(params, "id")) do
      json(conn, %{data: updated})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scheduling rule not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, rule} <- Coordinator.get_scheduling_rule(id),
         {:ok, _deleted} <- Coordinator.delete_scheduling_rule(rule) do
      send_resp(conn, :no_content, "")
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scheduling rule not found"})
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
