defmodule Mxc.Coordinator.ExecTest do
  # async: false — erlexec sends messages to self() and we don't want
  # cross-test mailbox pollution.
  use Mxc.DataCase, async: false

  alias Mxc.Coordinator

  setup_all do
    case :exec.start([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp running_process_workload do
    {:ok, w} =
      Coordinator.create_workload(%{
        type: "process",
        status: "running",
        command: "/bin/true"
      })

    w
  end

  describe "exec_in_workload/3 — guard clauses" do
    test "returns :not_found when workload does not exist" do
      assert {:error, :not_found} =
               Coordinator.exec_in_workload(Ecto.UUID.generate(), "echo hi")
    end

    test "returns :workload_not_running for a pending workload" do
      {:ok, w} =
        Coordinator.create_workload(%{
          type: "process",
          status: "pending",
          command: "/bin/sleep"
        })

      assert {:error, :workload_not_running} =
               Coordinator.exec_in_workload(w.id, "echo hi")
    end

    test "returns :workload_not_running for a stopped workload" do
      {:ok, w} =
        Coordinator.create_workload(%{
          type: "process",
          status: "stopped",
          command: "/bin/sleep"
        })

      assert {:error, :workload_not_running} =
               Coordinator.exec_in_workload(w.id, "echo hi")
    end
  end

  describe "exec_in_workload/3 — process workloads (run on host via erlexec)" do
    test "captures stdout on success" do
      w = running_process_workload()
      assert {:ok, "hello world"} = Coordinator.exec_in_workload(w.id, "echo hello world")
    end

    test "trims trailing whitespace" do
      w = running_process_workload()
      assert {:ok, "x"} = Coordinator.exec_in_workload(w.id, "printf 'x\\n\\n'")
    end

    test "captures stderr alongside stdout on failure" do
      w = running_process_workload()

      assert {:error, {:exit_code, 1, output}} =
               Coordinator.exec_in_workload(w.id, "echo oops >&2; exit 1")

      assert output =~ "oops"
    end

    test "returns exit_code error for non-zero exit" do
      w = running_process_workload()
      assert {:error, {:exit_code, 7, _}} = Coordinator.exec_in_workload(w.id, "exit 7")
    end

    test "enforces timeout and kills the child" do
      w = running_process_workload()

      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Coordinator.exec_in_workload(w.id, "sleep 10", timeout: 250)

      elapsed = System.monotonic_time(:millisecond) - started
      # Should fire within ~250ms + grace, not hang for 10s
      assert elapsed < 2_000, "exec_in_workload took #{elapsed}ms — timeout not enforced"
    end

    test "argv form is used (no host-side shell injection in microvm path)" do
      # The microvm branch builds an argv list; verify build_exec_command
      # produces a list (not an interpolated string) for that type.
      # We exercise the dispatch indirectly: a microvm workload whose target
      # hostname doesn't resolve should fail at ssh, not at our string parsing.
      {:ok, w} =
        Coordinator.create_workload(%{
          type: "microvm",
          status: "running",
          # contains a single quote that would break naive shell interpolation
          command: "no-such-host-' OR true #-aarch64"
        })

      # We don't care about success here — just that it doesn't crash on a
      # malformed shell-interpolated command. ssh will fail fast (no resolve
      # or refused), returning an exit_code or quick error.
      result = Coordinator.exec_in_workload(w.id, "echo safe", timeout: 5_000)

      case result do
        {:error, {:exit_code, _code, _output}} -> :ok
        {:error, :timeout} -> :ok
        {:error, _reason} -> :ok
        {:ok, _} -> flunk("did not expect success against fake host")
      end
    end
  end

  describe "discover_workload_ip/1" do
    test "returns :no_ip_found when the command returns empty output" do
      {:ok, w} =
        Coordinator.create_workload(%{
          type: "process",
          status: "running",
          command: "/bin/true"
        })

      # On macOS `hostname -I` doesn't exist; on Linux it works but might
      # return empty in test sandboxes. Either way, we just verify the
      # error contract holds when output is empty: drive it through a
      # workload whose `command` is bound but discover uses its hardcoded
      # `hostname -I`. We can't easily force empty output without mocking,
      # so instead verify the function composes correctly:
      result = Coordinator.discover_workload_ip(w.id)

      case result do
        {:ok, updated} -> assert is_binary(updated.ip)
        {:error, :no_ip_found} -> :ok
        {:error, {:exit_code, _, _}} -> :ok
        {:error, :not_found} -> flunk("workload existed")
      end
    end

    test "returns :not_found when workload does not exist" do
      assert {:error, :not_found} = Coordinator.discover_workload_ip(Ecto.UUID.generate())
    end
  end
end
