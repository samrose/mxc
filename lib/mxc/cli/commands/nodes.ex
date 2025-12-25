defmodule Mxc.CLI.Commands.Nodes do
  @moduledoc """
  CLI commands for managing nodes.
  """

  alias Mxc.CLI.{API, Output}

  def list(coordinator, format) do
    case API.get(coordinator, "/api/nodes") do
      {:ok, nodes} ->
        Output.render(nodes, format, &format_node_list/1)

      {:error, reason} ->
        Output.error("Failed to list nodes: #{reason}")
    end
  end

  def show(coordinator, node_id, format) do
    case API.get(coordinator, "/api/nodes/#{node_id}") do
      {:ok, node} ->
        Output.render(node, format, &format_node_detail/1)

      {:error, :not_found} ->
        Output.error("Node not found: #{node_id}")

      {:error, reason} ->
        Output.error("Failed to get node: #{reason}")
    end
  end

  defp format_node_list(nodes) when is_list(nodes) do
    headers = ["NODE", "STATUS", "CPU", "MEMORY", "WORKLOADS"]

    rows =
      Enum.map(nodes, fn node ->
        status = if node["healthy"], do: "healthy", else: "unhealthy"
        cpu = "#{node["available_cpu"]}/#{node["cpu_cores"]}"
        memory = "#{node["available_memory_mb"]}/#{node["memory_mb"]} MB"
        workloads = length(node["workloads"] || [])

        [node["node"], status, cpu, memory, workloads]
      end)

    Output.table(headers, rows)
  end

  defp format_node_detail(node) do
    status = if node["healthy"], do: "healthy", else: "unhealthy"

    """
    Node: #{node["node"]}
    Status: #{status}
    Heartbeat Age: #{node["heartbeat_age_ms"]} ms
    Connected At: #{node["connected_at"]}

    Resources:
      CPU Cores: #{node["cpu_cores"]} (#{node["available_cpu"]} available)
      Memory: #{node["memory_mb"]} MB (#{node["available_memory_mb"]} MB available)
      Hypervisor: #{node["hypervisor"] || "none"}

    Workloads: #{length(node["workloads"] || [])}
    #{format_workload_list(node["workloads"] || [])}
    """
  end

  defp format_workload_list([]), do: "  (none)"

  defp format_workload_list(workloads) do
    workloads
    |> Enum.map(&"  - #{&1}")
    |> Enum.join("\n")
  end
end
