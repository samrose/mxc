defmodule Mxc.Subprocess do
  @moduledoc """
  Erlexec-backed subprocess runner with deadline-based timeout and combined
  stdout/stderr capture.

  Two input forms:

    * argv list (`[charlist(), ...]`) — passed straight to `execve`, no shell
      parsing on the host side. Safe for user-supplied arguments.
    * charlist string — runs via `/bin/sh -c`, convenient for shell-style
      commands (pipes, redirects, expansion).

  Returns `{:ok, trimmed_output}`, `{:error, :timeout}`, or
  `{:error, {:exit_code, code, output}}`.

  Requires erlexec to be started — typically via `Mxc.Agent.Executor.init/1`
  or by callers in `setup_all`.
  """

  @type cmd :: charlist() | [charlist()]
  @type result ::
          {:ok, String.t()}
          | {:error, :timeout}
          | {:error, {:exit_code, integer(), String.t()}}
          | {:error, term()}

  @default_timeout 30_000
  @default_kill_timeout 5

  @spec run(cmd, keyword()) :: result
  def run(cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    kill_timeout = Keyword.get(opts, :kill_timeout, @default_kill_timeout)
    extra = Keyword.get(opts, :exec_opts, [])

    base = [:stdout, :stderr, :monitor, {:kill_timeout, kill_timeout}]
    exec_opts = base ++ extra

    with {:ok, resolved} <- resolve(cmd),
         {:ok, pid, os_pid} <- :exec.run(resolved, exec_opts) do
      deadline = System.monotonic_time(:millisecond) + timeout
      collect(pid, os_pid, deadline, [])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # erlexec's argv form does not perform PATH lookup — argv[0] must be an
  # absolute path. Resolve via System.find_executable/1 if the caller passed
  # a bare name like ~c"ssh". The charlist (shell-string) form is left as-is
  # because /bin/sh handles its own lookup.
  defp resolve([head | rest] = _argv) when is_list(head) do
    case List.to_string(head) do
      "/" <> _ ->
        {:ok, [head | rest]}

      name ->
        case System.find_executable(name) do
          nil -> {:error, {:executable_not_found, name}}
          path -> {:ok, [to_charlist(path) | rest]}
        end
    end
  end

  defp resolve(cmd) when is_list(cmd), do: {:ok, cmd}

  defp collect(pid, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stdout, ^os_pid, data} ->
        collect(pid, os_pid, deadline, [acc, data])

      {:stderr, ^os_pid, data} ->
        collect(pid, os_pid, deadline, [acc, data])

      {:DOWN, _ref, :process, ^pid, :normal} ->
        {:ok, acc |> IO.iodata_to_binary() |> String.trim()}

      {:DOWN, _ref, :process, ^pid, {:exit_status, status}} ->
        output = acc |> IO.iodata_to_binary() |> String.trim()
        {:error, {:exit_code, decode_exit_status(status), output}}
    after
      remaining ->
        :exec.stop(os_pid)
        {:error, :timeout}
    end
  end

  defp decode_exit_status(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _signal, _core} -> -1
    end
  end
end
