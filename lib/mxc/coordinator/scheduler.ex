defmodule Mxc.Coordinator.Scheduler do
  @moduledoc """
  Scheduler for placing workloads on agent nodes.

  Implements a simple bin-packing algorithm that places workloads
  on nodes based on available resources. Supports both spread and
  pack strategies.
  """

  alias Mxc.Coordinator.NodeManager

  @type workload_spec :: %{
          required(:cpu) => non_neg_integer(),
          required(:memory_mb) => non_neg_integer(),
          optional(:hypervisor) => atom(),
          optional(:constraints) => map()
        }

  @type placement_result :: {:ok, node()} | {:error, :no_capacity | :no_nodes}

  @doc """
  Places a workload on the best available node.

  Returns `{:ok, node}` if a suitable node is found, or
  `{:error, reason}` if placement fails.
  """
  @spec place(workload_spec()) :: placement_result()
  def place(workload_spec) do
    strategy = Application.get_env(:mxc, :scheduler_strategy, :spread)
    available_nodes = NodeManager.available_nodes()

    case available_nodes do
      [] ->
        {:error, :no_nodes}

      nodes ->
        nodes
        |> filter_by_constraints(workload_spec)
        |> filter_by_capacity(workload_spec)
        |> sort_by_strategy(strategy)
        |> select_node()
    end
  end

  @doc """
  Checks if a specific node can accommodate the workload.
  """
  @spec can_place?(map(), workload_spec()) :: boolean()
  def can_place?(node, spec) do
    has_capacity?(node, spec) and meets_constraints?(node, spec)
  end

  @doc """
  Calculates a placement score for a node (higher is better for placement).
  """
  @spec score(map(), atom()) :: number()
  def score(node, strategy \\ :spread) do
    case strategy do
      :spread ->
        # Prefer nodes with more available resources (spread load)
        node.available_cpu + node.available_memory_mb / 1024

      :pack ->
        # Prefer nodes with less available resources (bin-pack)
        -(node.available_cpu + node.available_memory_mb / 1024)

      :random ->
        :rand.uniform()
    end
  end

  # Private Functions

  defp filter_by_constraints(nodes, spec) do
    constraints = Map.get(spec, :constraints, %{})

    Enum.filter(nodes, fn node ->
      meets_constraints?(node, constraints)
    end)
  end

  defp filter_by_capacity(nodes, spec) do
    Enum.filter(nodes, fn node ->
      has_capacity?(node, spec)
    end)
  end

  defp sort_by_strategy(nodes, strategy) do
    Enum.sort_by(nodes, &score(&1, strategy), :desc)
  end

  defp select_node([]), do: {:error, :no_capacity}
  defp select_node([best | _]), do: {:ok, best.node}

  defp has_capacity?(node, spec) do
    required_cpu = Map.get(spec, :cpu, 0)
    required_memory = Map.get(spec, :memory_mb, 0)

    node.available_cpu >= required_cpu and
      node.available_memory_mb >= required_memory
  end

  defp meets_constraints?(node, spec) when is_map(spec) do
    constraints = Map.get(spec, :constraints, %{})
    meets_constraints?(node, constraints)
  end

  defp meets_constraints?(node, constraints) when is_map(constraints) do
    Enum.all?(constraints, fn {key, value} ->
      check_constraint(node, key, value)
    end)
  end

  defp check_constraint(node, :hypervisor, required) do
    # Node must have the required hypervisor
    node.hypervisor == required or required == :any
  end

  defp check_constraint(node, :node_name, pattern) when is_binary(pattern) do
    # Node name must match the pattern (supports wildcards)
    node_name = Atom.to_string(node.node)
    String.match?(node_name, ~r/#{pattern}/)
  end

  defp check_constraint(_node, _key, _value) do
    # Unknown constraints are ignored
    true
  end
end
