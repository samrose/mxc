defmodule Mxc.CLI do
  @moduledoc """
  CLI for interacting with the Mxc coordinator.

  Usage: mxc [options] <command>

  Options:
    -c, --coordinator URL   Coordinator API URL (default: $MXC_COORDINATOR or http://localhost:4000)
    -f, --format FORMAT     Output format: table, json (default: table)

  Commands:
    nodes                   List all nodes
    nodes <id>              Show node details
    workloads               List all workloads
    workloads deploy <file> Deploy workload from spec file
    workloads <id>          Show workload details
    workloads <id> stop     Stop a workload
    cluster status          Show cluster status
  """

  alias Mxc.CLI.Commands

  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        switches: [coordinator: :string, format: :string, help: :boolean],
        aliases: [c: :coordinator, f: :format, h: :help]
      )

    if opts[:help] do
      print_help()
    else
      coordinator =
        opts[:coordinator] ||
          System.get_env("MXC_COORDINATOR") ||
          "http://localhost:4000"

      format = String.to_atom(opts[:format] || "table")

      run_command(args, coordinator, format)
    end
  end

  defp run_command(["nodes"], coordinator, format) do
    Commands.Nodes.list(coordinator, format)
  end

  defp run_command(["nodes", node_id], coordinator, format) do
    Commands.Nodes.show(coordinator, node_id, format)
  end

  defp run_command(["workloads"], coordinator, format) do
    Commands.Workloads.list(coordinator, format)
  end

  defp run_command(["workloads", "deploy", spec_file], coordinator, format) do
    Commands.Workloads.deploy(coordinator, spec_file, format)
  end

  defp run_command(["workloads", workload_id, "stop"], coordinator, _format) do
    Commands.Workloads.stop(coordinator, workload_id)
  end

  defp run_command(["workloads", workload_id], coordinator, format) do
    Commands.Workloads.show(coordinator, workload_id, format)
  end

  defp run_command(["cluster", "status"], coordinator, format) do
    Commands.Cluster.status(coordinator, format)
  end

  defp run_command(["version"], _coordinator, _format) do
    IO.puts("mxc #{Application.spec(:mxc, :vsn)}")
  end

  defp run_command([], _coordinator, _format) do
    print_help()
  end

  defp run_command(unknown, _coordinator, _format) do
    IO.puts(:stderr, "Unknown command: #{Enum.join(unknown, " ")}")
    IO.puts(:stderr, "")
    print_help()
    System.halt(1)
  end

  defp print_help do
    IO.puts("""
    mxc - Infrastructure orchestration CLI

    Usage: mxc [options] <command>

    Options:
      -c, --coordinator URL   Coordinator API URL (default: $MXC_COORDINATOR or http://localhost:4000)
      -f, --format FORMAT     Output format: table, json (default: table)
      -h, --help              Show this help

    Commands:
      nodes                   List all nodes
      nodes <id>              Show node details
      workloads               List all workloads
      workloads deploy <file> Deploy workload from spec file
      workloads <id>          Show workload details
      workloads <id> stop     Stop a workload
      cluster status          Show cluster status
      version                 Show version

    Examples:
      mxc nodes
      mxc workloads deploy workload.json
      mxc -c http://coordinator:4000 cluster status
      mxc -f json nodes
    """)
  end
end
