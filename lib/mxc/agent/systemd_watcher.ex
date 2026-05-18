defmodule Mxc.Agent.SystemdWatcher do
  @moduledoc """
  Per-agent GenServer that polls systemd for microvm@*.service state changes
  and reports transitions back to the coordinator.

  Loop:

    1. Every `:poll_interval_ms` (default 2_000), enumerate loaded units via
       the backend (`Mxc.Agent.SystemdRunner.Backend.list_units/0`).
    2. Diff against the last-seen snapshot.
    3. For each transition, map the systemd state to a workload status and
       call `Mxc.Coordinator.update_workload/2` (in-BEAM) or `:rpc` to the
       coordinator node (in agent mode).

  systemd states map to workload statuses as:

      :activating    -> "starting"
      :active        -> "running"
      :failed        -> "failed"
      :inactive      -> "stopped"
      :unknown       -> ignored (transient or unit not yet loaded)

  Watcher state is in-memory only; it's a cache, not a source of truth.
  Source of truth is systemd itself (queried each tick) and Postgres (the
  workload table). On restart the watcher rebuilds its snapshot on first
  poll and emits no spurious transitions because nothing has been seen yet.

  ## Configuration

      config :mxc, Mxc.Agent.SystemdWatcher,
        poll_interval_ms: 2_000,
        enabled: true
  """

  use GenServer
  require Logger

  alias Mxc.Agent.SystemdRunner.Backend
  alias Mxc.Coordinator.Schemas.Workload

  defstruct last_seen: %{}, interval_ms: 2_000

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Trigger an immediate poll. Returns the transitions detected."
  def poll_now(server \\ __MODULE__), do: GenServer.call(server, :poll_now)

  @doc "Get the current snapshot."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # ── Server ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, 2_000)
    schedule_poll(interval)
    {:ok, %__MODULE__{interval_ms: interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    {transitions, new_state} = do_poll(state)
    Enum.each(transitions, &emit_transition/1)
    schedule_poll(state.interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    {transitions, new_state} = do_poll(state)
    Enum.each(transitions, &emit_transition/1)
    {:reply, transitions, new_state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.last_seen, state}
  end

  # ── Core poll/diff ──────────────────────────────────────────────────

  # Pure-ish: returns {transitions, new_state}. Emits no side effects.
  # Public so tests can drive it without GenServer scaffolding.
  @doc false
  def do_poll(%__MODULE__{last_seen: last} = state) do
    current =
      Backend.current().list_units()
      |> Map.new(fn %{id: id} = u -> {id, u} end)

    transitions = diff(last, current)
    {transitions, %{state | last_seen: current}}
  end

  @doc """
  Compute the transitions between two snapshots. Public for testing.

  Returns a list of `{:transition, id, from_state, to_state}` tuples.
  Newly-appeared units appear as `from_state: :absent`. Disappeared units
  appear as `to_state: :absent`.
  """
  def diff(last, current) when is_map(last) and is_map(current) do
    appeared =
      for {id, %{state: s}} <- current, not Map.has_key?(last, id) do
        {:transition, id, :absent, s}
      end

    changed =
      Enum.flat_map(current, fn {id, %{state: cur}} ->
        case Map.get(last, id) do
          %{state: prev} when prev != cur -> [{:transition, id, prev, cur}]
          _ -> []
        end
      end)

    disappeared =
      for {id, %{state: s}} <- last, not Map.has_key?(current, id) do
        {:transition, id, s, :absent}
      end

    appeared ++ changed ++ disappeared
  end

  # ── Side effects ────────────────────────────────────────────────────

  defp emit_transition({:transition, id, from, to}) do
    Logger.info("microvm@#{id} #{from} → #{to}")

    case workload_status_for(to) do
      nil ->
        :ok

      status ->
        notify_coordinator(id, status)
    end
  end

  defp workload_status_for(:activating), do: "starting"
  defp workload_status_for(:active), do: "running"
  defp workload_status_for(:failed), do: "failed"
  defp workload_status_for(:inactive), do: "stopped"
  defp workload_status_for(:absent), do: "stopped"
  defp workload_status_for(_), do: nil

  defp notify_coordinator(workload_id, status) do
    mode = Application.get_env(:mxc, :mode, :standalone)
    attrs = %{status: status}

    # systemd may have units for VMs we don't know about (manually-installed,
    # leftovers from before mxc, or just non-UUID names). Treat lookup failures
    # — including Ecto cast errors on non-UUID ids — as "not ours" and skip.
    try do
      case mode do
        m when m in [:standalone, :coordinator] ->
          case Mxc.Coordinator.get_workload(workload_id) do
            {:ok, %Workload{} = w} ->
              case Mxc.Coordinator.update_workload(w, attrs) do
                {:ok, _} -> :ok
                {:error, _} = err -> Logger.warning("update_workload failed: #{inspect(err)}")
              end

            {:error, :not_found} ->
              Logger.debug("Watcher saw microvm@#{workload_id} but coordinator has no such workload")
          end

        :agent ->
          case Node.list() |> Enum.find(&coordinator_node?/1) do
            nil ->
              Logger.warning(
                "Agent has no coordinator peer; can't report #{workload_id}=#{status}"
              )

            coordinator ->
              with {:ok, %Workload{} = w} <-
                     :rpc.call(coordinator, Mxc.Coordinator, :get_workload, [workload_id]) do
                :rpc.call(coordinator, Mxc.Coordinator, :update_workload, [w, attrs])
              end
          end
      end
    rescue
      e in [Ecto.Query.CastError, Ecto.QueryError] ->
        Logger.debug("Watcher skipped non-mxc unit microvm@#{workload_id}: #{Exception.message(e)}")

        :ok
    end
  end

  defp coordinator_node?(node) do
    node |> Atom.to_string() |> String.starts_with?("coordinator@")
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
