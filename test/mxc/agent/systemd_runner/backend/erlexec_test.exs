defmodule Mxc.Agent.SystemdRunner.Backend.ErlexecTest do
  @moduledoc """
  Tier-2 integration tests for the real systemd backend.

  Exercises `Mxc.Agent.SystemdRunner.Backend.Erlexec` against real `systemctl`
  and a stub `microvm@.service` unit template (ExecStart=/bin/sleep infinity).
  `build_runner/3` is **deliberately not tested here** — that path does a real
  `nix build` and belongs to tier-4 (full microVM boot). Tier-2 verifies the
  shell-out boundary: helper script + sudoers + state-dir + systemctl + state
  parsing.

  ## Required host setup

  Run `scripts/setup-linux-test-host.sh` once. It is idempotent and installs:

    * `/usr/local/bin/mxc-vm-helper` (the privileged helper)
    * `/etc/sudoers.d/mxc-vm-helper` (passwordless sudo for the current user)
    * `/etc/systemd/system/microvm@.service` (stub unit running `sleep infinity`)
    * `/var/lib/microvms/` with appropriate ownership

  ## How to run

      MIX_RUN_LINUX_TESTS=1 mix test --include linux_systemd

  Or, from macOS, against a remote linux-builder:

      just test-linux
  """

  use ExUnit.Case, async: false

  @moduletag :linux_systemd

  alias Mxc.Agent.SystemdRunner.Backend.Erlexec
  alias Mxc.Subprocess

  @state_dir "/var/lib/microvms"

  setup_all do
    case :exec.start([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Sanity-check the host setup before running any test. If the helper
    # isn't reachable via sudo we skip the whole module rather than report
    # a confusing failure inside each test.
    case Subprocess.run([~c"sudo", ~c"-n", ~c"/usr/local/bin/mxc-vm-helper", ~c"list"]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPING tier-2 systemd tests: helper not reachable via sudo.
        Run scripts/setup-linux-test-host.sh first. Detail: #{inspect(reason)}
        """)

        :ignore
    end
  end

  setup do
    id = "mxc-test-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    on_exit(fn ->
      # Best-effort cleanup. Errors are ignored — the next test will use a
      # fresh randomised id.
      _ = Erlexec.stop_unit(id)
      _ = Subprocess.run([~c"sudo", ~c"rm", ~c"-rf", to_charlist("#{@state_dir}/#{id}")])
    end)

    %{id: id}
  end

  # ── helper: poll until the unit reaches a target state ──────────────

  defp poll_until_state(id, target, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> Erlexec.unit_status(id) end)
    |> Stream.each(fn _ -> Process.sleep(150) end)
    |> Enum.find(fn state ->
      state == target or System.monotonic_time(:millisecond) >= deadline
    end)
  end

  # ── Tests ────────────────────────────────────────────────────────────

  describe "create_state/1" do
    test "creates the per-workload state dir", %{id: id} do
      assert :ok = Erlexec.create_state(id)
      assert File.dir?("#{@state_dir}/#{id}")
    end

    test "is idempotent on repeat invocation", %{id: id} do
      assert :ok = Erlexec.create_state(id)
      assert :ok = Erlexec.create_state(id)
    end
  end

  describe "set_flake/2" do
    test "writes the flake reference to the state dir", %{id: id} do
      :ok = Erlexec.create_state(id)
      assert :ok = Erlexec.set_flake(id, "git+file:///tmp/example-flake")

      contents = File.read!("#{@state_dir}/#{id}/flake") |> String.trim()
      assert contents == "git+file:///tmp/example-flake"
    end

    test "fails if state dir not yet created", %{id: id} do
      assert {:error, _} = Erlexec.set_flake(id, "git+file:///tmp/x")
    end
  end

  describe "start_unit/1 + unit_status/1" do
    test "starts the stub unit and reports :active", %{id: id} do
      :ok = Erlexec.create_state(id)
      :ok = Erlexec.set_flake(id, "git+file:///tmp/stub")

      assert :ok = Erlexec.start_unit(id)
      assert :active = poll_until_state(id, :active)
    end

    test "reports :inactive or :unknown for an un-started id", %{id: id} do
      assert Erlexec.unit_status(id) in [:inactive, :unknown]
    end
  end

  describe "stop_unit/1" do
    test "stops a running unit and state returns to :inactive", %{id: id} do
      :ok = Erlexec.create_state(id)
      :ok = Erlexec.set_flake(id, "git+file:///tmp/stub")
      :ok = Erlexec.start_unit(id)
      :active = poll_until_state(id, :active)

      assert :ok = Erlexec.stop_unit(id)
      state = poll_until_state(id, :inactive)
      assert state in [:inactive, :unknown]
    end
  end

  describe "list_units/0" do
    test "enumerates a running stub with state and id", %{id: id} do
      :ok = Erlexec.create_state(id)
      :ok = Erlexec.set_flake(id, "git+file:///tmp/stub")
      :ok = Erlexec.start_unit(id)
      :active = poll_until_state(id, :active)

      units = Erlexec.list_units()
      ours = Enum.find(units, fn u -> u.id == id end)

      assert ours, "list_units did not return our id #{id}; saw #{inspect(units)}"
      assert ours.state == :active
    end
  end
end
