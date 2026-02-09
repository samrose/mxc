defmodule Mxc.Coordinator.Dispatcher do
  @moduledoc """
  Bridges the Coordinator's scheduling decisions to the Agent's Executor.

  In standalone mode: calls the local Executor directly.
  In distributed mode: RPCs to the agent node that owns the workload.
  """

  require Logger

  alias Mxc.Coordinator.Schemas.Workload

  @doc """
  Dispatches a workload to be started on its assigned node.
  The workload must have a node_id set (from placement).
  """
  def dispatch_start(%Workload{} = workload) do
    case find_executor(workload.node_id) do
      {:local, module} ->
        try do
          module.start_workload(workload)
        catch
          :exit, reason ->
            Logger.error("Executor not available: #{inspect(reason)}")
            {:error, :executor_not_available}
        end

      {:remote, node_name, module} ->
        case :rpc.call(node_name, module, :start_workload, [workload]) do
          {:badrpc, reason} ->
            Logger.error("RPC to agent failed: #{inspect(reason)}")
            {:error, {:rpc_failed, reason}}

          result ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Dispatches a stop command for a workload.
  """
  def dispatch_stop(%Workload{} = workload) do
    case find_executor(workload.node_id) do
      {:local, module} ->
        try do
          module.stop_workload(workload.id)
        catch
          :exit, reason ->
            Logger.error("Executor not available: #{inspect(reason)}")
            {:error, :executor_not_available}
        end

      {:remote, node_name, module} ->
        case :rpc.call(node_name, module, :stop_workload, [workload.id]) do
          {:badrpc, reason} ->
            Logger.error("RPC to agent failed: #{inspect(reason)}")
            {:error, {:rpc_failed, reason}}

          result ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private

  defp find_executor(node_id) do
    mode = Application.get_env(:mxc, :mode, :standalone)

    case mode do
      :standalone ->
        # Same BEAM node — call Executor directly
        {:local, Mxc.Agent.Executor}

      :coordinator ->
        # Find the Erlang node for this agent by node_id
        case find_agent_node(node_id) do
          nil ->
            Logger.warning("No agent node found for node_id #{node_id}")
            {:error, :agent_not_found}

          erlang_node ->
            {:remote, erlang_node, Mxc.Agent.Executor}
        end

      :agent ->
        {:error, :not_coordinator}
    end
  end

  defp find_agent_node(node_id) do
    # In distributed mode, agents register with their node_id.
    # We look through connected Erlang nodes to find the one
    # that owns this node_id.
    # For now, try all agent nodes and ask them.
    Node.list()
    |> Enum.find(fn erlang_node ->
      case :rpc.call(erlang_node, Application, :get_env, [:mxc, :node_id]) do
        ^node_id -> true
        _ -> false
      end
    end)
  end
end
