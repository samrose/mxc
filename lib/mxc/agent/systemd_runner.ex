defmodule Mxc.Agent.SystemdRunner do
  @moduledoc """
  Defers per-VM lifecycle to the host's `microvm.host` NixOS module via
  systemd, while mxc retains all cluster-level orchestration.

  mxc still:
    * decides placement (datalox rules in the coordinator)
    * triggers starts and stops via `systemctl`
    * monitors state (`Mxc.Agent.SystemdWatcher`) and reports back
    * applies cluster-wide policy (`Mxc.Coordinator.Reactor`)

  systemd handles only the local actuation: cgroup membership, restart
  semantics, journal capture, and the pre-start hooks that wire up TAP
  devices and virtiofs daemons.

  ## Deployment requirements

  The agent host must have:

    1. `microvm.host.enable = true` in its NixOS configuration.
    2. A `microvm` user with appropriate group membership (`kvm`).
    3. The mxc helper script at `/usr/local/bin/mxc-vm-helper`
       (see `priv/bin/mxc-vm-helper`).
    4. A sudoers entry:

           microvm ALL=(root) NOPASSWD: /usr/local/bin/mxc-vm-helper

  ## Workflow per workload

      create_state → set_flake → build_runner → start_unit

  Each step shells out via the configured backend (see
  `Mxc.Agent.SystemdRunner.Backend`). Tests use the `Mock` backend; production
  uses `Erlexec`.
  """

  require Logger

  alias Mxc.Agent.SystemdRunner.Backend
  alias Mxc.Coordinator.Schemas.Workload

  @doc """
  Start a microVM workload via systemd.

  Returns `{:ok, %{kind: :systemd, unit: unit_name}}` on success.
  """
  def start_workload(%Workload{type: "microvm"} = workload) do
    backend = Backend.current()
    id = workload.id
    flake_ref = flake_ref()
    config_name = workload.command
    hv = hypervisor()

    with :ok <- backend.create_state(id),
         :ok <- backend.set_flake(id, flake_ref),
         :ok <- backend.build_runner(id, config_name, hv),
         :ok <- backend.start_unit(id) do
      Logger.info("Started microvm@#{id} (#{config_name}, #{hv}) via systemd")
      {:ok, %{kind: :systemd, unit: unit_name(id)}}
    else
      {:error, reason} = err ->
        Logger.error("SystemdRunner failed at #{stage_of(reason)} for #{id}: #{inspect(reason)}")
        err
    end
  end

  def start_workload(%Workload{type: type}) do
    {:error, {:unsupported_type, type}}
  end

  @doc """
  Stop a microVM workload's systemd unit.
  """
  def stop_workload(%{unit: _unit, id: id}), do: stop_workload_by_id(id)
  def stop_workload(%Workload{id: id, type: "microvm"}), do: stop_workload_by_id(id)
  def stop_workload(_), do: {:error, :not_microvm}

  defp stop_workload_by_id(id) do
    case Backend.current().stop_unit(id) do
      :ok -> :ok
      err -> err
    end
  end

  @doc "Current state of a workload's unit. Returns :unknown if not loaded."
  def status(id), do: Backend.current().unit_status(id)

  @doc "Enumerate all currently-loaded microvm@*.service units."
  def list_units, do: Backend.current().list_units()

  @doc "Systemd unit name for a given workload id."
  def unit_name(id), do: "microvm@#{id}.service"

  # ── Private ─────────────────────────────────────────────────────────

  defp flake_ref do
    Application.get_env(:mxc, :flake_ref) ||
      case Application.get_env(:mxc, :flake_dir) do
        nil -> raise "Set :mxc, :flake_ref or :flake_dir to use SystemdRunner"
        dir -> "git+file://#{Path.expand(dir)}"
      end
  end

  defp hypervisor do
    case Mxc.Platform.preferred_hypervisor() do
      :qemu -> "qemu"
      :vfkit -> "vfkit"
      :cloud_hypervisor -> "cloud-hypervisor"
      :firecracker -> "firecracker"
      other -> Atom.to_string(other)
    end
  end

  # Best-effort: classify where the failure happened by inspecting the reason.
  # Helpful in logs; not relied on for correctness.
  defp stage_of(reason) do
    s = inspect(reason)

    cond do
      s =~ "create_state" -> "create"
      s =~ "set_flake" -> "flake"
      s =~ "build" -> "build"
      s =~ "start" -> "start"
      true -> "unknown"
    end
  end
end
