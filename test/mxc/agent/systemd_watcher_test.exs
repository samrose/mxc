defmodule Mxc.Agent.SystemdWatcherTest do
  use Mxc.DataCase, async: false

  alias Mxc.Agent.SystemdWatcher
  alias Mxc.Agent.SystemdRunner.Backend.Mock
  alias Mxc.Coordinator

  setup do
    {:ok, _pid} = start_supervised(Mock)
    :ok
  end

  defp unit(id, state, sub \\ "running") do
    %{id: id, state: state, sub_state: sub, active_enter_ts: nil}
  end

  describe "diff/2 — pure logic" do
    test "appearing unit produces :absent → state transition" do
      last = %{}
      current = %{"a" => unit("a", :active)}

      assert [{:transition, "a", :absent, :active}] =
               SystemdWatcher.diff(last, current)
    end

    test "state change produces prev → current transition" do
      last = %{"a" => unit("a", :activating)}
      current = %{"a" => unit("a", :active)}

      assert [{:transition, "a", :activating, :active}] =
               SystemdWatcher.diff(last, current)
    end

    test "disappearing unit produces state → :absent transition" do
      last = %{"a" => unit("a", :active)}
      current = %{}

      assert [{:transition, "a", :active, :absent}] =
               SystemdWatcher.diff(last, current)
    end

    test "no change produces no transitions" do
      last = %{"a" => unit("a", :active)}
      current = %{"a" => unit("a", :active)}

      assert [] = SystemdWatcher.diff(last, current)
    end

    test "multiple units, mixed transitions" do
      last = %{"a" => unit("a", :active), "b" => unit("b", :activating)}
      current = %{"b" => unit("b", :failed), "c" => unit("c", :active)}

      transitions = SystemdWatcher.diff(last, current)

      assert {:transition, "c", :absent, :active} in transitions
      assert {:transition, "b", :activating, :failed} in transitions
      assert {:transition, "a", :active, :absent} in transitions
      assert length(transitions) == 3
    end
  end

  describe "do_poll/1 — full pipeline (no GenServer)" do
    test "first poll picks up everything as new" do
      Mock.set_units([unit("a", :active), unit("b", :activating)])

      {transitions, new_state} = SystemdWatcher.do_poll(%SystemdWatcher{})

      ids = for {:transition, id, :absent, _} <- transitions, do: id
      assert "a" in ids
      assert "b" in ids
      assert map_size(new_state.last_seen) == 2
    end

    test "second poll detects only the change" do
      Mock.set_units([unit("a", :active)])

      {_, state1} = SystemdWatcher.do_poll(%SystemdWatcher{})

      Mock.set_units([unit("a", :failed)])
      {transitions, state2} = SystemdWatcher.do_poll(state1)

      assert [{:transition, "a", :active, :failed}] = transitions
      assert state2.last_seen["a"].state == :failed
    end
  end

  describe "poll_now/0 — GenServer + DB integration" do
    test "active transition pushes status=\"running\" to the coordinator" do
      {:ok, workload} =
        Coordinator.create_workload(%{
          type: "microvm",
          status: "starting",
          command: "mxc-vm-aarch64"
        })

      Mock.set_units([unit(workload.id, :active)])

      {:ok, _pid} =
        start_supervised({SystemdWatcher, [poll_interval_ms: 60_000, name: :test_watcher]})

      transitions = SystemdWatcher.poll_now(:test_watcher)
      assert [{:transition, _id, :absent, :active}] = transitions

      {:ok, reloaded} = Coordinator.get_workload(workload.id)
      assert reloaded.status == "running"
    end

    test "failed transition pushes status=\"failed\"" do
      {:ok, workload} =
        Coordinator.create_workload(%{
          type: "microvm",
          status: "running",
          command: "mxc-vm-aarch64"
        })

      {:ok, _pid} =
        start_supervised({SystemdWatcher, [poll_interval_ms: 60_000, name: :fail_watcher]})

      # First poll: unit is active
      Mock.set_units([unit(workload.id, :active)])
      _ = SystemdWatcher.poll_now(:fail_watcher)

      # Second poll: unit failed
      Mock.set_units([unit(workload.id, :failed)])
      _ = SystemdWatcher.poll_now(:fail_watcher)

      {:ok, reloaded} = Coordinator.get_workload(workload.id)
      assert reloaded.status == "failed"
    end

    test "transitions for unknown workloads do not crash" do
      {:ok, _pid} =
        start_supervised({SystemdWatcher, [poll_interval_ms: 60_000, name: :unknown_watcher]})

      Mock.set_units([unit("not-a-real-workload-id", :active)])

      # Should not raise even though the workload isn't in the DB
      assert [_] = SystemdWatcher.poll_now(:unknown_watcher)
    end
  end
end
