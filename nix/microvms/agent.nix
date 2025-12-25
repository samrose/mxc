# MicroVM that runs the pre-built mxc agent
{ self, pkgs, lib, config, nixpkgs, ... }:

let
  # Import the agent package
  mxc-agent = pkgs.callPackage ../../nix/packages/agent.nix {
    beamPackages = pkgs.beam.packages.erlang;
  };
in {
  # Override base microVM configuration
  microvm = {
    mem = lib.mkForce 1024;  # 1GB for agent workloads

    # Override network interface with different MAC
    interfaces = lib.mkForce [{
      type = "user";
      id = "qemu";
      mac = "02:00:00:01:02:01";
    }];

    # Override port forwarding
    # Note: libcluster_postgres handles discovery, but Erlang distribution still needs
    # direct connectivity. With QEMU user-mode, host can't initiate to VM without forwarding.
    forwardPorts = lib.mkForce [
      { host.port = 2222; guest.port = 22; }
      { host.port = 4001; guest.port = 4001; }   # Agent API port
      { host.port = 14369; guest.port = 4369; }  # EPMD (offset to avoid host conflict)
      { host.port = 19100; guest.port = 9100; }  # Erlang distribution
    ];
  };

  # NixOS configuration
  networking.hostName = "mxc-agent";
  networking.useDHCP = true;

  # Map host machine hostname to QEMU gateway IP for Erlang distribution
  # This allows the agent to connect to coordinator@<host-hostname>
  networking.extraHosts = ''
    10.0.2.2 Sams-MacBook-Pro-2
  '';
  networking.firewall.allowedTCPPorts = [ 22 4001 4369 ] ++ (lib.range 9100 9155);

  # Auto-login for console access
  services.getty.autologinUser = "root";

  # SSH access
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.root.initialPassword = "mxc";

  # Create mxc user for running the agent (erlexec doesn't allow root)
  users.users.mxc = {
    isSystemUser = true;
    group = "mxc";
    home = "/var/lib/mxc";
    createHome = true;
  };
  users.groups.mxc = {};

  # Include the pre-built agent and debugging tools
  environment.systemPackages = with pkgs; [
    mxc-agent
    htop
    curl
    jq
  ];

  # Systemd service to run the pre-built agent
  systemd.services.mxc-agent = {
    description = "Mxc Agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      MXC_MODE = "agent";
      MXC_CLUSTER_STRATEGY = "postgres";
      # Database for libcluster_postgres (host from VM perspective)
      DATABASE_HOST = "10.0.2.2";
      DATABASE_PORT = "5432";
      DATABASE_USER = "mxc";
      DATABASE_PASSWORD = "";
      DATABASE_NAME = "mxc_dev";  # Must match coordinator's database
      # Erlang distribution
      RELEASE_NAME = "agent";
      RELEASE_COOKIE = "mxc-cluster-cookie";
      RELEASE_NODE = "agent@mxc-agent";
    };

    serviceConfig = {
      Type = "exec";
      ExecStart = "${mxc-agent}/bin/agent start";
      User = "mxc";
      Group = "mxc";
      WorkingDirectory = "/var/lib/mxc";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Disable unnecessary services
  documentation.enable = false;
  services.udisks2.enable = false;

  system.stateVersion = "24.05";
}
