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
  end
end
