defmodule Mxc.Coordinator.FactProjection do
  @moduledoc """
  Pure functions that map Ecto structs to normalized datalox fact tuples.

  Facts use the datalox format: {:predicate_name, [value1, value2, ...]}
  """

  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent}

  def project(%Node{} = node) do
    cpu_free = node.cpu_total - node.cpu_used
    mem_free = node.memory_total - node.memory_used

    base = [
      {:node, [node.id, node.hostname, String.to_atom(node.status)]},
      {:node_resources, [node.id, node.cpu_total, node.memory_total]},
      {:node_resources_used, [node.id, node.cpu_used, node.memory_used]},
      {:node_resources_free, [node.id, cpu_free, mem_free]}
    ]

    heartbeat =
      if node.last_heartbeat_at do
        [{:node_heartbeat, [node.id, DateTime.to_unix(node.last_heartbeat_at)]}]
      else
        []
      end

    hypervisor =
      if node.hypervisor do
        [{:node_capability, [node.id, :hypervisor, String.to_atom(node.hypervisor)]}]
      else
        []
      end

    capabilities =
      (node.capabilities || %{})
      |> Enum.map(fn {k, v} -> {:node_capability, [node.id, k, v]} end)

    base ++ heartbeat ++ hypervisor ++ capabilities
  end

  def project(%Workload{} = wl) do
    base = [
      {:workload, [wl.id, String.to_atom(wl.type), String.to_atom(wl.status)]},
      {:workload_resources, [wl.id, wl.cpu_required, wl.memory_required]}
    ]

    placement =
      if wl.node_id do
        [{:workload_placement, [wl.id, wl.node_id]}]
      else
        []
      end

    constraints =
      (wl.constraints || %{})
      |> Enum.map(fn {k, v} -> {:workload_constraint, [wl.id, k, v]} end)

    base ++ placement ++ constraints
  end

  def project(%WorkloadEvent{} = event) do
    ts = if event.inserted_at, do: DateTime.to_unix(event.inserted_at), else: 0
    [{:workload_event, [event.workload_id, event.event_type, ts]}]
  end

  def diff(current_facts, desired_facts) do
    current_set = MapSet.new(current_facts)
    desired_set = MapSet.new(desired_facts)

    to_assert = MapSet.difference(desired_set, current_set) |> MapSet.to_list()
    to_retract = MapSet.difference(current_set, desired_set) |> MapSet.to_list()

    {to_assert, to_retract}
  end
end
