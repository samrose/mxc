defmodule Mxc.Agent.MicroVM do
  @moduledoc """
  Launches and manages microvm.nix virtual machines.

  Uses `nix build` to produce a runner script from the flake's
  nixosConfigurations, then executes it via erlexec. Runners are
  cached in a state directory to avoid redundant builds.

  Supported VM configurations are defined in flake.nix under
  nixosConfigurations (e.g. mxc-vm-aarch64, mxc-vm-workload-aarch64).
  """

  require Logger

  @doc """
  Returns the directory where VM runners and state are stored.
  Uses a fixed path under the user's home to avoid nix shell per-session tmp dirs.
  """
  def state_dir do
    dir = Application.get_env(:mxc, :microvm_state_dir) ||
      Path.join(System.user_home!(), ".mxc/microvms")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Lists the known nixosConfiguration names from the flake that match
  the current host architecture.
  """
  def available_configs do
    arch = Mxc.Platform.guest_arch()

    # These are defined in flake.nix nixosConfigurations
    [
      "mxc-vm-#{arch}",
      "mxc-vm-workload-#{arch}",
      "mxc-agent-#{arch}"
    ]
  end

  @doc """
  Builds the runner for a given nixosConfiguration name.
  Returns {:ok, runner_path} or {:error, reason}.

  The runner is a script that launches the VM with the configured
  hypervisor (qemu on macOS, cloud-hypervisor on Linux).

  Results are cached — subsequent calls return the cached path.
  """
  def build_runner(config_name, opts \\ []) do
    flake_dir = opts[:flake_dir] || find_flake_dir()
    runner_dir = Path.join(state_dir(), config_name)
    out_link = Path.join(runner_dir, "result")
    runner_path = Path.join([out_link, "bin", "microvm-run"])

    if File.exists?(runner_path) and not Keyword.get(opts, :force, false) do
      {:ok, resolve_symlinks(runner_path)}
    else
      File.mkdir_p!(runner_dir)
      do_build_runner(flake_dir, config_name, runner_dir)
    end
  end

  @doc """
  Starts a microVM from a built runner.
  Returns {:ok, %{pid: pid, os_pid: os_pid, config: config_name}} or {:error, reason}.
  """
  def start_vm(config_name, opts \\ []) do
    case build_runner(config_name, opts) do
      {:ok, runner_path} ->
        vm_dir = Path.join(state_dir(), "run-#{config_name}-#{System.unique_integer([:positive])}")
        File.mkdir_p!(vm_dir)

        Logger.info("Starting microVM #{config_name} from #{runner_path}")

        exec_opts = [
          :stdout,
          :stderr,
          :monitor,
          {:cd, to_charlist(vm_dir)}
        ]

        case :exec.run(to_charlist(runner_path), exec_opts) do
          {:ok, pid, os_pid} ->
            {:ok, %{pid: pid, os_pid: os_pid, config: config_name, vm_dir: vm_dir}}

          {:error, reason} ->
            Logger.error("Failed to start microVM #{config_name}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a running microVM.
  """
  def stop_vm(%{os_pid: os_pid}) do
    :exec.stop(os_pid)
    :ok
  end

  def stop_vm(_), do: {:error, :invalid_vm_state}

  @doc """
  Gets the status of a microVM.
  """
  def vm_status(%{os_pid: os_pid}) do
    case :exec.status(os_pid) do
      {:status, :running} -> :running
      {:status, {:exit_status, 0}} -> :stopped
      {:status, {:exit_status, _}} -> :failed
      _ -> :unknown
    end
  end

  def vm_status(_), do: :unknown

  # Private

  defp do_build_runner(flake_dir, config_name, runner_dir) do
    # microvm.runner is a set keyed by hypervisor (qemu, vfkit, cloud-hypervisor, etc.)
    # Select the preferred hypervisor for this platform
    hypervisor = hypervisor_attr_name()
    nix_attr = ".#nixosConfigurations.#{config_name}.config.microvm.runner.#{hypervisor}"
    out_link = Path.join(runner_dir, "result")
    nix_bin = find_nix_binary()

    Logger.info("Building microVM runner: #{nix_bin} build #{nix_attr}")

    case System.cmd(nix_bin, ["build", nix_attr, "-o", out_link],
           cd: flake_dir,
           stderr_to_stdout: true,
           env: [{"NIX_CONFIG", "experimental-features = nix-command flakes"}]
         ) do
      {_output, 0} ->
        # The runner script is at result/bin/microvm-run
        runner_path = Path.join([out_link, "bin", "microvm-run"])

        if File.exists?(runner_path) do
          # Use the nix store path directly — don't copy, as runner scripts
          # reference other nix store paths that would break if copied.
          # The -o out_link is a GC root, keeping it alive.
          real_path = resolve_symlinks(runner_path)
          {:ok, real_path}
        else
          {:error, "runner script not found at #{runner_path}"}
        end

      {output, exit_code} ->
        Logger.error("nix build failed (exit #{exit_code}): #{output}")
        {:error, "nix build failed: #{String.slice(output, 0, 500)}"}
    end
  end

  defp resolve_symlinks(path) do
    case File.read_link(path) do
      {:ok, target} ->
        # If relative, resolve against the directory
        resolved =
          if String.starts_with?(target, "/") do
            target
          else
            path |> Path.dirname() |> Path.join(target) |> Path.expand()
          end

        resolve_symlinks(resolved)

      {:error, _} ->
        # Not a symlink — return the real path
        Path.expand(path)
    end
  end

  defp hypervisor_attr_name do
    # Map Platform hypervisor atoms to microvm.nix runner attribute names
    case Mxc.Platform.preferred_hypervisor() do
      :qemu -> "qemu"
      :vfkit -> "vfkit"
      :cloud_hypervisor -> "cloud-hypervisor"
      :firecracker -> "firecracker"
      _ -> "qemu"
    end
  end

  defp find_nix_binary do
    # Try the PATH first, then known locations
    case System.find_executable("nix") do
      nil ->
        cond do
          File.exists?("/nix/var/nix/profiles/default/bin/nix") ->
            "/nix/var/nix/profiles/default/bin/nix"

          File.exists?("/run/current-system/sw/bin/nix") ->
            "/run/current-system/sw/bin/nix"

          true ->
            # Last resort — rely on PATH
            "nix"
        end

      path ->
        path
    end
  end

  defp find_flake_dir do
    # In dev, the flake is at the project root
    # In release, it should be configured
    Application.get_env(:mxc, :flake_dir) ||
      Path.join(File.cwd!(), ".")
  end
end
