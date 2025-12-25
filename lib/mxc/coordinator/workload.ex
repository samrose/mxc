defmodule Mxc.Coordinator.Workload do
  @moduledoc """
  Manages workload lifecycle and state.

  Workloads can be:
  - :process - A system process managed by erlexec
  - :microvm - A microVM managed by the hypervisor

  Workload states:
  - :pending - Waiting to be scheduled
  - :starting - Being started on a node
  - :running - Currently running
  - :stopping - Being stopped
  - :stopped - Gracefully stopped
  - :failed - Failed to start or crashed
  """

  use GenServer
  require Logger

  alias Mxc.Coordinator.NodeManager

  @type workload_type :: :process | :microvm
  @type workload_status :: :pending | :starting | :running | :stopping | :stopped | :failed

  @type workload :: %{
          id: String.t(),
          type: workload_type(),
          status: workload_status(),
          spec: map(),
          node: node() | nil,
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          error: String.t() | nil
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a workload on the specified node.
  """
  @spec start(node(), map()) :: {:ok, workload()} | {:error, term()}
  def start(node, spec) do
    GenServer.call(__MODULE__, {:start, node, spec})
  end

  @doc """
  Stops a running workload.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(workload_id) do
    GenServer.call(__MODULE__, {:stop, workload_id})
  end

  @doc """
  Lists all workloads.
  """
  @spec list_all() :: [workload()]
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  @doc """
  Gets a specific workload by ID.
  """
  @spec get(String.t()) :: {:ok, workload()} | {:error, :not_found}
  def get(workload_id) do
    GenServer.call(__MODULE__, {:get, workload_id})
  end

  @doc """
  Clears all workloads (for development/debugging).
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Force-removes a stuck workload by ID.
  """
  def force_remove(workload_id) do
    GenServer.call(__MODULE__, {:force_remove, workload_id})
  end

  @doc """
  Updates workload status (called by agents).
  """
  def update_status(workload_id, status, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:update_status, workload_id, status, metadata})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to cluster events for handling node failures
    Phoenix.PubSub.subscribe(Mxc.PubSub, "cluster:events")

    {:ok, %{workloads: %{}}}
  end

  @impl true
  def handle_call({:start, node, spec}, _from, state) do
    workload_id = generate_id()

    workload = %{
      id: workload_id,
      type: Map.get(spec, :type, :process),
      status: :starting,
      spec: spec,
      node: node,
      started_at: nil,
      stopped_at: nil,
      error: nil
    }

    # Request the agent to start the workload
    case request_start(node, workload) do
      :ok ->
        Logger.info("Starting workload #{workload_id} on #{node}")
        new_state = put_in(state.workloads[workload_id], workload)
        {:reply, {:ok, workload}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to start workload #{workload_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      workload ->
        # Request the agent to stop the workload
        request_stop(workload.node, workload_id)

        updated_workload = %{workload | status: :stopping}
        new_state = put_in(state.workloads[workload_id], updated_workload)

        Logger.info("Stopping workload #{workload_id}")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    workloads = Map.values(state.workloads)
    {:reply, workloads, state}
  end

  @impl true
  def handle_call({:get, workload_id}, _from, state) do
    case Map.get(state.workloads, workload_id) do
      nil -> {:reply, {:error, :not_found}, state}
      workload -> {:reply, {:ok, workload}, state}
    end
  end

  @impl true
  def handle_call(:clear_all, _from, _state) do
    Logger.info("Clearing all workloads")
    {:reply, :ok, %{workloads: %{}}}
  end

  @impl true
  def handle_call({:force_remove, workload_id}, _from, state) do
    Logger.info("Force removing workload #{workload_id}")
    {:reply, :ok, %{state | workloads: Map.delete(state.workloads, workload_id)}}
  end

  @impl true
  def handle_cast({:update_status, workload_id, status, metadata}, state) do
    case Map.get(state.workloads, workload_id) do
      nil ->
        {:noreply, state}

      workload ->
        updated_workload =
          workload
          |> Map.put(:status, status)
          |> maybe_set_started_at(status)
          |> maybe_set_stopped_at(status)
          |> maybe_set_error(metadata)

        # Broadcast status change
        Phoenix.PubSub.broadcast(
          Mxc.PubSub,
          "workloads:#{workload_id}",
          {:workload_status, updated_workload}
        )

        # Update node resources if workload completed
        if status in [:stopped, :failed] do
          NodeManager.update_resources(workload.node, %{
            workloads: Enum.reject(workload.spec[:workloads] || [], &(&1.id == workload_id))
          })
        end

        new_state = put_in(state.workloads[workload_id], updated_workload)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:node_down, node}, state) do
    # Mark all workloads on the failed node as failed
    updated_workloads =
      state.workloads
      |> Enum.map(fn {id, workload} ->
        if workload.node == node and workload.status in [:starting, :running] do
          {id, %{workload | status: :failed, error: "Node disconnected"}}
        else
          {id, workload}
        end
      end)
      |> Map.new()

    {:noreply, %{state | workloads: updated_workloads}}
  end

  # Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp request_start(node, workload) do
    try do
      GenServer.call({Mxc.Agent.Executor, node}, {:start_workload, workload})
    catch
      :exit, _ -> {:error, :node_unreachable}
    end
  end

  defp request_stop(node, workload_id) do
    try do
      GenServer.cast({Mxc.Agent.Executor, node}, {:stop_workload, workload_id})
    catch
      :exit, _ -> :ok
    end
  end

  defp maybe_set_started_at(workload, :running) do
    if workload.started_at, do: workload, else: %{workload | started_at: DateTime.utc_now()}
  end

  defp maybe_set_started_at(workload, _), do: workload

  defp maybe_set_stopped_at(workload, status) when status in [:stopped, :failed] do
    %{workload | stopped_at: DateTime.utc_now()}
  end

  defp maybe_set_stopped_at(workload, _), do: workload

  defp maybe_set_error(workload, %{error: error}), do: %{workload | error: error}
  defp maybe_set_error(workload, _), do: workload
end
