defmodule Mxc.Agent.SystemdRunner.Backend do
  @moduledoc """
  Behaviour for the privileged-systemd boundary used by `Mxc.Agent.SystemdRunner`.

  Two implementations:

    * `Mxc.Agent.SystemdRunner.Backend.Erlexec` — real impl. Shells out to
      `/usr/local/bin/mxc-vm-helper` via `sudo`, supervised by erlexec.
    * `Mxc.Agent.SystemdRunner.Backend.Mock` — test impl. Records every call
      into an Agent so tests can assert against it, and returns canned
      responses. No real systemd needed — runs on macOS/CI.

  The active backend is selected at runtime via app config:

      config :mxc, :systemd_backend, Mxc.Agent.SystemdRunner.Backend.Erlexec

  Call `Mxc.Agent.SystemdRunner.Backend.current/0` to fetch the configured
  module.
  """

  @type id :: String.t()
  @type flake_ref :: String.t()
  @type config_name :: String.t()
  @type hypervisor :: String.t()
  @type unit_state :: :active | :activating | :inactive | :failed | :unknown
  @type unit_info :: %{
          id: id(),
          state: unit_state(),
          sub_state: String.t() | nil,
          active_enter_ts: integer() | nil
        }
  @type reason :: term()

  @doc "Create per-workload state dir under /var/lib/microvms/<id>."
  @callback create_state(id) :: :ok | {:error, reason}

  @doc "Write the flake reference text file used by microvm-host on rebuild."
  @callback set_flake(id, flake_ref) :: :ok | {:error, reason}

  @doc "Build the runner via nix and symlink it as `current`."
  @callback build_runner(id, config_name, hypervisor) :: :ok | {:error, reason}

  @doc "systemctl start microvm@<id>.service."
  @callback start_unit(id) :: :ok | {:error, reason}

  @doc "systemctl stop microvm@<id>.service."
  @callback stop_unit(id) :: :ok | {:error, reason}

  @doc "Lookup state of a single unit. Returns :unknown if the unit isn't loaded."
  @callback unit_status(id) :: unit_state()

  @doc "Enumerate currently-loaded microvm@*.service units with their state."
  @callback list_units() :: [unit_info()]

  @doc """
  The configured backend module — read from app config every call so tests
  can swap it per case if needed.
  """
  @spec current() :: module()
  def current do
    Application.get_env(:mxc, :systemd_backend, Mxc.Agent.SystemdRunner.Backend.Erlexec)
  end
end
