defmodule Mxc.CLI.Commands.Cluster do
  @moduledoc """
  CLI commands for cluster status.
  """

  alias Mxc.CLI.{API, Output}

  def status(coordinator, format) do
    case API.get(coordinator, "/api/cluster/status") do
      {:ok, status} ->
        Output.render(status, format, &format_cluster_status/1)

      {:error, reason} ->
        Output.error("Failed to get cluster status: #{reason}")
    end
  end

  defp format_cluster_status(status) do
    """
    Cluster Status
    ==============

    Nodes:
      Total: #{status["node_count"]}
      Healthy: #{status["nodes_healthy"]}

    Workloads:
      Total: #{status["workload_count"]}
      Running: #{status["workloads_running"]}

    Resources:
      Total CPU: #{status["total_cpu"]} cores
      Available CPU: #{status["available_cpu"]} cores
      Total Memory: #{status["total_memory_mb"]} MB
      Available Memory: #{status["available_memory_mb"]} MB
    """
  end
end
