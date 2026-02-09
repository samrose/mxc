defmodule Mxc.Agent.MicroVMTest do
  use ExUnit.Case, async: true

  alias Mxc.Agent.MicroVM

  describe "available_configs/0" do
    test "returns a list of config names" do
      configs = MicroVM.available_configs()
      assert is_list(configs)
      assert length(configs) > 0

      for config <- configs do
        assert is_binary(config)
        assert config =~ ~r/^mxc-/
      end
    end

    test "includes architecture suffix" do
      arch = Mxc.Platform.guest_arch()
      configs = MicroVM.available_configs()
      assert Enum.all?(configs, &String.ends_with?(&1, arch))
    end
  end

  describe "state_dir/0" do
    test "returns a path" do
      dir = MicroVM.state_dir()
      assert is_binary(dir)
      assert dir =~ "microvms"
    end
  end
end
