defmodule MxcWeb.API.ClusterController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def status(conn, _params) do
    status = Coordinator.cluster_status()
    json(conn, status)
  end
end
