defmodule Mxc.Coordinator.Schemas.NodeTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator.Schemas.Node

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        hostname: "agent1.local",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 0,
        memory_used: 0
      }

      changeset = Node.changeset(%Node{}, attrs)
      assert changeset.valid?
    end

    test "invalid without hostname" do
      changeset = Node.changeset(%Node{}, %{status: "available"})
      refute changeset.valid?
      assert %{hostname: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status is one of allowed values" do
      attrs = %{hostname: "test", status: "bogus", cpu_total: 1, memory_total: 1024, cpu_used: 0, memory_used: 0}
      changeset = Node.changeset(%Node{}, attrs)
      refute changeset.valid?
    end
  end
end
