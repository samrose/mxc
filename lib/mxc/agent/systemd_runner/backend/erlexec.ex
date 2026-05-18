defmodule Mxc.Agent.SystemdRunner.Backend.Erlexec do
  @moduledoc """
  Production backend for `Mxc.Agent.SystemdRunner`.

  All operations shell out to `/usr/local/bin/mxc-vm-helper` via `sudo`,
  supervised by erlexec. The helper is the single sudo-permitted binary;
  see `priv/bin/mxc-vm-helper` for the script.

  ## Required sudoers entry

      microvm ALL=(root) NOPASSWD: /usr/local/bin/mxc-vm-helper

  This backend assumes the calling Elixir process runs as the `microvm` user
  on a NixOS host with `microvm.host.enable = true`.
  """

  @behaviour Mxc.Agent.SystemdRunner.Backend

  alias Mxc.Subprocess

  @helper Application.compile_env(:mxc, :systemd_helper, "/usr/local/bin/mxc-vm-helper")
  @sudo Application.compile_env(:mxc, :sudo_bin, "/usr/bin/sudo")
  @systemctl Application.compile_env(:mxc, :systemctl_bin, "/run/current-system/sw/bin/systemctl")

  # ── Behaviour ───────────────────────────────────────────────────────

  @impl true
  def create_state(id), do: helper(["init", id])

  @impl true
  def set_flake(id, flake_ref), do: helper(["set-flake", id, flake_ref])

  @impl true
  def build_runner(id, config_name, hypervisor) do
    # nix builds can be slow; helper passes through to nix build with a 15-min
    # cap on the Elixir side. The helper itself doesn't enforce a timeout.
    helper(["build", id, config_name, hypervisor], timeout: 15 * 60_000)
  end

  @impl true
  def start_unit(id), do: helper(["start", id])

  @impl true
  def stop_unit(id), do: helper(["stop", id])

  @impl true
  def unit_status(id) do
    case Subprocess.run(
           [to_charlist(@systemctl), ~c"is-active", to_charlist(unit_name(id))],
           timeout: 5_000
         ) do
      {:ok, output} -> parse_active_state(output)
      {:error, {:exit_code, _, output}} -> parse_active_state(output)
      {:error, _} -> :unknown
    end
  end

  @impl true
  def list_units do
    # `systemctl list-units --type=service --all --no-legend --plain microvm@*`
    args = [
      to_charlist(@systemctl),
      ~c"list-units",
      ~c"--type=service",
      ~c"--all",
      ~c"--no-legend",
      ~c"--plain",
      ~c"microvm@*"
    ]

    case Subprocess.run(args, timeout: 10_000) do
      {:ok, output} -> parse_unit_list(output)
      _ -> []
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp helper(args, opts \\ []) do
    argv = [to_charlist(@sudo), to_charlist(@helper) | Enum.map(args, &to_charlist/1)]

    case Subprocess.run(argv, opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp unit_name(id), do: "microvm@#{id}.service"

  defp parse_active_state(output) do
    case String.trim(output) do
      "active" -> :active
      "activating" -> :activating
      "inactive" -> :inactive
      "failed" -> :failed
      "deactivating" -> :inactive
      _ -> :unknown
    end
  end

  defp parse_unit_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_unit_line/1)
  end

  # systemctl --plain output: UNIT LOAD ACTIVE SUB DESCRIPTION...
  defp parse_unit_line(line) do
    case String.split(line, ~r/\s+/, parts: 5) do
      [unit, _load, active, sub | _] ->
        case Regex.run(~r/^microvm@(.+)\.service$/, unit) do
          [_, id] ->
            [
              %{
                id: id,
                state: parse_active_state(active),
                sub_state: sub,
                active_enter_ts: nil
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
