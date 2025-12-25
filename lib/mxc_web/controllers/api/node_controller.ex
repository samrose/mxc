defmodule MxcWeb.API.NodeController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    nodes = Coordinator.list_nodes()
    json(conn, nodes)
  end

  def show(conn, %{"id" => node_id}) do
    case Coordinator.get_node(node_id) do
      {:ok, node} ->
        json(conn, node)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Node not found"})
    end
  end
end
