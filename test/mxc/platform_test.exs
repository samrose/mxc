defmodule Mxc.PlatformTest do
  use ExUnit.Case, async: true

  alias Mxc.Platform

  describe "os/0" do
    test "returns an atom" do
      assert is_atom(Platform.os())
    end

    test "returns :darwin on macOS" do
      # This test only passes on macOS
      if :os.type() == {:unix, :darwin} do
        assert Platform.os() == :darwin
      end
    end
  end

  describe "arch/0" do
    test "returns a known architecture" do
      assert Platform.arch() in [:aarch64, :x86_64, :unknown]
    end
  end

  describe "guest_arch/0" do
    test "returns a string" do
      assert is_binary(Platform.guest_arch())
    end
  end

  describe "available_hypervisors/0" do
    test "returns a list" do
      assert is_list(Platform.available_hypervisors())
    end

    test "only contains valid hypervisor atoms" do
      valid = [:qemu, :vfkit, :cloud_hypervisor, :firecracker]

      for hv <- Platform.available_hypervisors() do
        assert hv in valid
      end
    end
  end

  describe "nix_available?/0" do
    test "returns boolean" do
      assert is_boolean(Platform.nix_available?())
    end
  end

  describe "validate_workload_type/1" do
    test "process is always valid" do
      assert :ok = Platform.validate_workload_type("process")
    end

    test "unknown type is invalid" do
      assert {:error, _} = Platform.validate_workload_type("docker")
    end

    test "microvm validation depends on platform" do
      result = Platform.validate_workload_type("microvm")
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "node_capabilities/0" do
    test "returns a map with os and arch" do
      caps = Platform.node_capabilities()
      assert is_map(caps)
      assert caps["os"] in ["darwin", "linux"]
      assert caps["arch"] in ["aarch64", "x86_64", "unknown"]
      assert caps["process"] == "true"
    end
  end

  describe "can_run_processes?/0" do
    test "always true" do
      assert Platform.can_run_processes?() == true
    end
  end
end
