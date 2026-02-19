defmodule Mxc.Coordinator.Schemas.WorkloadTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator.Schemas.Workload

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        type: "process",
        status: "pending",
        command: "echo hello",
        cpu_required: 1,
        memory_required: 256
      }

      changeset = Workload.changeset(%Workload{}, attrs)
      assert changeset.valid?
    end

    test "invalid without command" do
      attrs = %{type: "process", status: "pending"}
      changeset = Workload.changeset(%Workload{}, attrs)
      refute changeset.valid?
    end

    test "validates type is process or microvm" do
      attrs = %{type: "invalid", status: "pending", command: "echo"}
      changeset = Workload.changeset(%Workload{}, attrs)
      refute changeset.valid?
    end

    test "accepts ip field" do
      attrs = %{
        type: "process",
        status: "running",
        command: "echo hello",
        ip: "192.168.1.10"
      }

      changeset = Workload.changeset(%Workload{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :ip) == "192.168.1.10"
    end

    test "ip field is optional" do
      attrs = %{type: "process", status: "pending", command: "echo hello"}
      changeset = Workload.changeset(%Workload{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :ip) == nil
    end
  end
end
