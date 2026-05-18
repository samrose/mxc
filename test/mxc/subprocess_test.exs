defmodule Mxc.SubprocessTest do
  # async: false — erlexec sends messages to self(); avoid mailbox cross-talk.
  use ExUnit.Case, async: false

  alias Mxc.Subprocess

  setup_all do
    case :exec.start([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "run/2 — argv list form (no shell)" do
    test "captures stdout" do
      assert {:ok, "hello"} = Subprocess.run([~c"echo", ~c"hello"])
    end

    test "argv elements are not interpreted as shell" do
      # Single-quote in the argument would break a shell-interpolated form;
      # in argv form it's just a literal character.
      assert {:ok, "it's safe"} = Subprocess.run([~c"echo", ~c"it's safe"])
    end

    test "returns :not_found-style error for missing executable" do
      # erlexec returns {:error, [exit_status: N, ...]} or similar
      result = Subprocess.run([~c"/nonexistent/binary/please"])
      assert {:error, _} = result
    end
  end

  describe "run/2 — charlist form (via /bin/sh -c)" do
    test "captures stdout" do
      assert {:ok, "ok"} = Subprocess.run(~c"echo ok")
    end

    test "supports shell pipes and redirects" do
      assert {:ok, "hi"} = Subprocess.run(~c"printf 'hi\\nbye' | head -n1")
    end

    test "captures stderr alongside stdout on failure" do
      assert {:error, {:exit_code, 1, output}} =
               Subprocess.run(~c"echo oops >&2; exit 1")

      assert output =~ "oops"
    end

    test "returns exit_code error for non-zero exit" do
      assert {:error, {:exit_code, 7, _}} = Subprocess.run(~c"exit 7")
    end
  end

  describe "run/2 — timeout" do
    test "enforces deadline and kills child" do
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Subprocess.run(~c"sleep 10", timeout: 200)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_000, "timeout not enforced — took #{elapsed}ms"
    end

    test "respects custom timeout option" do
      assert {:ok, "done"} = Subprocess.run(~c"echo done", timeout: 5_000)
    end
  end
end
