defmodule Mxc.CLI.Commands.Workloads do
  @moduledoc """
  CLI commands for managing workloads.
  """

  alias Mxc.CLI.{API, Output}

  def list(coordinator, format) do
    case API.get(coordinator, "/api/workloads") do
      {:ok, workloads} ->
        Output.render(workloads, format, &format_workload_list/1)

      {:error, reason} ->
        Output.error("Failed to list workloads: #{reason}")
    end
  end

  def show(coordinator, workload_id, format) do
    case API.get(coordinator, "/api/workloads/#{workload_id}") do
      {:ok, workload} ->
        Output.render(workload, format, &format_workload_detail/1)

      {:error, :not_found} ->
        Output.error("Workload not found: #{workload_id}")

      {:error, reason} ->
        Output.error("Failed to get workload: #{reason}")
    end
  end

  def deploy(coordinator, spec_file, format) do
    case File.read(spec_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, spec} ->
            case API.post(coordinator, "/api/workloads", spec) do
              {:ok, workload} ->
                Output.success("Workload deployed: #{workload["id"]}")
                Output.render(workload, format, &format_workload_detail/1)

              {:error, reason} ->
                Output.error("Failed to deploy workload: #{reason}")
            end

          {:error, _} ->
            Output.error("Invalid JSON in spec file: #{spec_file}")
        end

      {:error, :enoent} ->
        Output.error("Spec file not found: #{spec_file}")

      {:error, reason} ->
        Output.error("Failed to read spec file: #{reason}")
    end
  end

  def stop(coordinator, workload_id) do
    case API.post(coordinator, "/api/workloads/#{workload_id}/stop", %{}) do
      {:ok, _} ->
        Output.success("Workload stopped: #{workload_id}")

      {:error, :not_found} ->
        Output.error("Workload not found: #{workload_id}")

      {:error, reason} ->
        Output.error("Failed to stop workload: #{reason}")
    end
  end

  defp format_workload_list(workloads) when is_list(workloads) do
    headers = ["ID", "TYPE", "STATUS", "NODE", "STARTED"]

    rows =
      Enum.map(workloads, fn w ->
        started =
          case w["started_at"] do
            nil -> "-"
            ts -> ts
          end

        [w["id"], w["type"], w["status"], w["node"] || "-", started]
      end)

    Output.table(headers, rows)
  end

  defp format_workload_detail(workload) do
    """
    Workload: #{workload["id"]}
    Type: #{workload["type"]}
    Status: #{workload["status"]}
    Node: #{workload["node"] || "(not assigned)"}

    Times:
      Started: #{workload["started_at"] || "-"}
      Stopped: #{workload["stopped_at"] || "-"}

    #{format_error(workload["error"])}
    Spec:
    #{format_spec(workload["spec"])}
    """
  end

  defp format_error(nil), do: ""
  defp format_error(error), do: "Error: #{error}\n"

  defp format_spec(spec) when is_map(spec) do
    spec
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
    |> Enum.map(&"  #{&1}")
    |> Enum.join("\n")
  end

  defp format_spec(_), do: "  (none)"
end
