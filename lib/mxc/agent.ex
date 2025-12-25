defmodule Mxc.Agent do
  @moduledoc """
  The Agent context handles workload execution on worker nodes.

  The agent is responsible for:
  - Connecting to the coordinator cluster via libcluster
  - Reporting node resources and health
  - Executing workloads (processes and microVMs)
  - Managing the workload lifecycle on the local node
  """

  alias Mxc.Agent.{Executor, Health, VMManager}

  @doc """
  Returns the current node's resource information.
  """
  def node_info do
    Health.get_info()
  end

  @doc """
  Returns list of workloads running on this agent.
  """
  def list_workloads do
    Executor.list_workloads()
  end

  @doc """
  Starts a workload on this agent.
  """
  def start_workload(spec) do
    Executor.start_workload(spec)
  end

  @doc """
  Stops a workload running on this agent.
  """
  def stop_workload(workload_id) do
    Executor.stop_workload(workload_id)
  end

  @doc """
  Returns the configured hypervisor, if any.
  """
  def hypervisor do
    Application.get_env(:mxc, :hypervisor)
  end

  @doc """
  Checks if this agent can run microVMs.
  """
  def can_run_microvms? do
    hypervisor() != nil and VMManager.available?()
  end
end
