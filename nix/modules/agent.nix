# Agent NixOS module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.mxc.agent;
in {
  options.services.mxc.agent = {
    enable = mkEnableOption "Mxc agent service";

    package = mkOption {
      type = types.package;
      description = "Mxc agent package";
    };

    clusterStrategy = mkOption {
      type = types.enum [ "postgres" "gossip" "dns" "epmd" ];
      default = "postgres";
      description = "Libcluster topology strategy";
    };

    database = {
      host = mkOption {
        type = types.str;
        description = "PostgreSQL host (for libcluster_postgres)";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
      };

      name = mkOption {
        type = types.str;
        default = "mxc";
      };

      user = mkOption {
        type = types.str;
        default = "mxc";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };

    gossip = {
      port = mkOption {
        type = types.port;
        default = 45892;
        description = "Gossip multicast port";
      };

      secretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing gossip secret";
      };
    };

    dns = {
      query = mkOption {
        type = types.str;
        default = "mxc.local";
        description = "DNS query for node discovery";
      };
    };

    clusterHosts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of cluster hosts for EPMD strategy";
    };

    erlangCookie = mkOption {
      type = types.str;
      default = "";
      description = "Must match coordinator's cookie";
    };

    erlangCookieFile = mkOption {
      type = types.nullOr types.path;
      default = null;
    };

    resources = {
      cpuCores = mkOption {
        type = types.int;
        default = 0;
        description = "CPU cores available for workloads (0 = auto-detect)";
      };

      memoryMB = mkOption {
        type = types.int;
        default = 0;
        description = "Memory (MB) available for workloads (0 = auto-detect)";
      };
    };

    hypervisor = mkOption {
      type = types.nullOr (types.enum [ "qemu" "cloud-hypervisor" "vfkit" ]);
      default = null;
      description = "Hypervisor for running microVMs (null = process-only mode)";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.mxc-agent = {
      description = "Mxc Agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        RELEASE_NAME = "agent";
        RELEASE_NODE = "agent@${config.networking.hostName}";
        MXC_MODE = "agent";
        MXC_CLUSTER_STRATEGY = cfg.clusterStrategy;
        DATABASE_HOST = cfg.database.host;
        DATABASE_PORT = toString cfg.database.port;
        DATABASE_NAME = cfg.database.name;
        DATABASE_USER = cfg.database.user;
        MXC_AGENT_CPU = toString cfg.resources.cpuCores;
        MXC_AGENT_MEMORY = toString cfg.resources.memoryMB;
        MXC_HYPERVISOR = if cfg.hypervisor != null then cfg.hypervisor else "";
        MXC_GOSSIP_PORT = toString cfg.gossip.port;
        MXC_DNS_QUERY = cfg.dns.query;
        MXC_CLUSTER_HOSTS = concatStringsSep "," cfg.clusterHosts;
      } // cfg.extraEnv;

      script = ''
        ${optionalString (cfg.database.passwordFile != null) ''
          export DATABASE_PASSWORD="$(cat ${cfg.database.passwordFile})"
        ''}

        ${optionalString (cfg.gossip.secretFile != null) ''
          export MXC_GOSSIP_SECRET="$(cat ${cfg.gossip.secretFile})"
        ''}

        ${optionalString (cfg.erlangCookieFile != null) ''
          export RELEASE_COOKIE="$(cat ${cfg.erlangCookieFile})"
        ''}
        ${optionalString (cfg.erlangCookieFile == null && cfg.erlangCookie != "") ''
          export RELEASE_COOKIE="${cfg.erlangCookie}"
        ''}

        exec ${cfg.package}/bin/agent start
      '';

      serviceConfig = {
        Type = "exec";
        User = "root";  # Needed for hypervisor access
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Include hypervisor packages if configured
    environment.systemPackages = mkIf (cfg.hypervisor != null) (
      if cfg.hypervisor == "qemu" then [ pkgs.qemu ]
      else if cfg.hypervisor == "cloud-hypervisor" then [ pkgs.cloud-hypervisor ]
      else []
    );

    # Enable KVM if using hypervisor
    virtualisation.libvirtd.enable = mkIf (cfg.hypervisor != null) true;

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      4369  # EPMD
    ] ++ (lib.range 9100 9155);  # Erlang distribution ports

    networking.firewall.allowedUDPPorts = mkIf (cfg.clusterStrategy == "gossip") [
      cfg.gossip.port
    ];
  };
}
