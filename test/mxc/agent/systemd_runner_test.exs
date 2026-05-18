defmodule Mxc.Agent.SystemdRunnerTest do
  use ExUnit.Case, async: false

  alias Mxc.Agent.SystemdRunner
  alias Mxc.Agent.SystemdRunner.Backend.Mock
  alias Mxc.Coordinator.Schemas.Workload

  setup do
    {:ok, _pid} = start_supervised(Mock)
    :ok
  end

  defp workload(attrs) do
    Map.merge(
      %Workload{
        id: "test-workload-1",
        type: "microvm",
        command: "mxc-vm-aarch64",
        status: "starting"
      },
      attrs
    )
  end

  describe "start_workload/1 — happy path" do
    test "calls create_state → set_flake → build_runner → start_unit, in order" do
      assert {:ok, %{kind: :systemd, unit: "microvm@test-workload-1.service"}} =
               SystemdRunner.start_workload(workload(%{}))

      calls = Mock.calls()
      callbacks = Enum.map(calls, fn {cb, _} -> cb end)

      assert callbacks == [:create_state, :set_flake, :build_runner, :start_unit]
    end

    test "passes the workload id to every step" do
      id = "abc-def-123"
      SystemdRunner.start_workload(workload(%{id: id}))

      for {_cb, [arg0 | _]} <- Mock.calls() do
        assert arg0 == id
      end
    end

    test "passes the nixosConfiguration name as command to build_runner" do
      SystemdRunner.start_workload(workload(%{command: "pg2une-postgres-aarch64"}))

      assert {:build_runner, [_id, "pg2une-postgres-aarch64", _hv]} =
               Enum.find(Mock.calls(), fn {cb, _} -> cb == :build_runner end)
    end

    test "passes a non-empty hypervisor string to build_runner" do
      SystemdRunner.start_workload(workload(%{}))

      assert {:build_runner, [_id, _cfg, hv]} =
               Enum.find(Mock.calls(), fn {cb, _} -> cb == :build_runner end)

      assert hv in ["qemu", "vfkit", "cloud-hypervisor", "firecracker"]
    end

    test "writes a flake reference derived from :mxc, :flake_dir" do
      SystemdRunner.start_workload(workload(%{}))

      assert {:set_flake, [_id, flake_ref]} =
               Enum.find(Mock.calls(), fn {cb, _} -> cb == :set_flake end)

      assert String.starts_with?(flake_ref, "git+file:///")
    end
  end

  describe "start_workload/1 — failure paths" do
    test "stops at create_state failure; does not call subsequent steps" do
      Mock.stub(:create_state, fn _id -> {:error, :permission_denied} end)

      assert {:error, :permission_denied} = SystemdRunner.start_workload(workload(%{}))

      callbacks = Enum.map(Mock.calls(), fn {cb, _} -> cb end)
      assert callbacks == [:create_state]
    end

    test "stops at build_runner failure; never reaches start_unit" do
      Mock.stub(:build_runner, fn _id, _cfg, _hv ->
        {:error, {:exit_code, 1, "nix build failed: missing input"}}
      end)

      assert {:error, {:exit_code, 1, _}} = SystemdRunner.start_workload(workload(%{}))

      callbacks = Enum.map(Mock.calls(), fn {cb, _} -> cb end)
      assert callbacks == [:create_state, :set_flake, :build_runner]
    end

    test "stops at start_unit failure" do
      Mock.stub(:start_unit, fn _id -> {:error, :unit_not_found} end)

      assert {:error, :unit_not_found} = SystemdRunner.start_workload(workload(%{}))

      callbacks = Enum.map(Mock.calls(), fn {cb, _} -> cb end)
      assert callbacks == [:create_state, :set_flake, :build_runner, :start_unit]
    end

    test "rejects non-microvm workload type" do
      assert {:error, {:unsupported_type, "process"}} =
               SystemdRunner.start_workload(workload(%{type: "process"}))

      assert Mock.calls() == []
    end
  end

  describe "stop_workload/1" do
    test "calls backend.stop_unit/1 with workload id" do
      assert :ok = SystemdRunner.stop_workload(workload(%{id: "stop-me"}))
      assert [{:stop_unit, ["stop-me"]}] = Mock.calls()
    end

    test "accepts a runner-state map (kind: :systemd)" do
      assert :ok =
               SystemdRunner.stop_workload(%{
                 kind: :systemd,
                 unit: "microvm@x.service",
                 id: "x"
               })

      assert [{:stop_unit, ["x"]}] = Mock.calls()
    end
  end

  describe "status/1" do
    test "delegates to backend.unit_status/1" do
      Mock.set_unit_state("abc", :active)
      assert :active = SystemdRunner.status("abc")
      assert [{:unit_status, ["abc"]}] = Mock.calls()
    end

    test "returns :unknown if the unit has never been set" do
      assert :unknown = SystemdRunner.status("never-started")
    end
  end

  describe "unit_name/1" do
    test "is `microvm@<id>.service`" do
      assert SystemdRunner.unit_name("abc-123") == "microvm@abc-123.service"
    end
  end
end
