defmodule Mxc.Agent.SystemdRunner.Backend.Mock do
  @moduledoc """
  Test backend for `Mxc.Agent.SystemdRunner`.

  Records every call into an `Agent` so tests can assert against the
  sequence of operations. Returns canned responses configured per-test
  via `stub/2` and `set_units/1`.

  ## Usage

      setup do
        start_supervised!(Mxc.Agent.SystemdRunner.Backend.Mock)
        # Optional: override defaults
        Mxc.Agent.SystemdRunner.Backend.Mock.stub(:start_unit, fn _id -> :ok end)
        Mxc.Agent.SystemdRunner.Backend.Mock.set_units([
          %{id: "abc", state: :active, sub_state: "running", active_enter_ts: nil}
        ])
        :ok
      end

      test "..." do
        # ...exercise SystemdRunner...
        assert [{:create_state, [_id]}, {:set_flake, [_id, _flake]}, ...] =
                 Mxc.Agent.SystemdRunner.Backend.Mock.calls()
      end

  Calls accumulate in chronological order. Use `reset/0` between tests if
  you don't use `start_supervised!`.
  """

  @behaviour Mxc.Agent.SystemdRunner.Backend

  use Agent

  @name __MODULE__

  def start_link(opts \\ []) do
    Agent.start_link(fn -> init_state() end, name: opts[:name] || @name)
  end

  defp init_state do
    %{
      calls: [],
      stubs: %{},
      units: %{},
      unit_list: []
    }
  end

  @doc "All recorded calls, in chronological order."
  def calls(name \\ @name) do
    Agent.get(name, fn st -> Enum.reverse(st.calls) end)
  end

  @doc "Clear recorded calls and stubs. Useful between tests."
  def reset(name \\ @name) do
    Agent.update(name, fn _ -> init_state() end)
  end

  @doc """
  Override the default return value for a callback.

      stub(:start_unit, fn _id -> {:error, :nope} end)
  """
  def stub(name \\ @name, callback, fun) when is_atom(callback) and is_function(fun) do
    Agent.update(name, fn st -> %{st | stubs: Map.put(st.stubs, callback, fun)} end)
  end

  @doc "Set the unit state returned by `unit_status/1`, per id."
  def set_unit_state(name \\ @name, id, state) do
    Agent.update(name, fn st -> %{st | units: Map.put(st.units, id, state)} end)
  end

  @doc "Set the list returned by `list_units/0`."
  def set_units(name \\ @name, units) when is_list(units) do
    Agent.update(name, fn st -> %{st | unit_list: units} end)
  end

  # ── Behaviour ───────────────────────────────────────────────────────

  @impl true
  def create_state(id), do: record(:create_state, [id])

  @impl true
  def set_flake(id, flake_ref), do: record(:set_flake, [id, flake_ref])

  @impl true
  def build_runner(id, config_name, hypervisor),
    do: record(:build_runner, [id, config_name, hypervisor])

  @impl true
  def start_unit(id), do: record(:start_unit, [id])

  @impl true
  def stop_unit(id), do: record(:stop_unit, [id])

  @impl true
  def unit_status(id) do
    Agent.get_and_update(@name, fn st ->
      calls = [{:unit_status, [id]} | st.calls]
      result = Map.get(st.units, id, :unknown)
      {result, %{st | calls: calls}}
    end)
  end

  @impl true
  def list_units do
    Agent.get_and_update(@name, fn st ->
      calls = [{:list_units, []} | st.calls]
      {st.unit_list, %{st | calls: calls}}
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp record(callback, args) do
    Agent.get_and_update(@name, fn st ->
      calls = [{callback, args} | st.calls]

      result =
        case Map.get(st.stubs, callback) do
          nil -> :ok
          fun when is_function(fun) -> apply(fun, args)
        end

      {result, %{st | calls: calls}}
    end)
  end

end
