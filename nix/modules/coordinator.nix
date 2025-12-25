# Coordinator NixOS module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.mxc.coordinator;
in {
  options.services.mxc.coordinator = {
    enable = mkEnableOption "Mxc coordinator service";

    package = mkOption {
      type = types.package;
      description = "Mxc coordinator package";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "HTTP API port";
    };

    uiEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the web UI";
    };

    clusterStrategy = mkOption {
      type = types.enum [ "postgres" "gossip" "dns" "epmd" ];
      default = "postgres";
      description = "Libcluster topology strategy";
    };

    schedulerStrategy = mkOption {
      type = types.enum [ "spread" "pack" ];
      default = "spread";
      description = "Workload scheduling strategy";
    };

    database = {
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "PostgreSQL host";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = mkOption {
        type = types.str;
        default = "mxc";
        description = "Database name";
      };

      user = mkOption {
        type = types.str;
        default = "mxc";
        description = "Database user";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing database password";
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

    erlangCookie = mkOption {
      type = types.str;
      default = "";
      description = "Erlang distribution cookie for cluster communication";
    };

    erlangCookieFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing Erlang cookie (alternative to erlangCookie)";
    };

    secretKeyBaseFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing Phoenix secret key base";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.mxc-coordinator = {
      description = "Mxc Coordinator";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" ];

      environment = {
        RELEASE_NAME = "coordinator";
        RELEASE_NODE = "coordinator@${config.networking.hostName}";
        MXC_MODE = "coordinator";
        MXC_UI_ENABLED = if cfg.uiEnabled then "true" else "false";
        MXC_CLUSTER_STRATEGY = cfg.clusterStrategy;
        MXC_SCHEDULER_STRATEGY = cfg.schedulerStrategy;
        PORT = toString cfg.port;
        PHX_SERVER = "true";
        PHX_HOST = config.networking.hostName;
        DATABASE_HOST = cfg.database.host;
        DATABASE_PORT = toString cfg.database.port;
        DATABASE_NAME = cfg.database.name;
        DATABASE_USER = cfg.database.user;
        MXC_GOSSIP_PORT = toString cfg.gossip.port;
        MXC_DNS_QUERY = cfg.dns.query;
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

        ${optionalString (cfg.secretKeyBaseFile != null) ''
          export SECRET_KEY_BASE="$(cat ${cfg.secretKeyBaseFile})"
        ''}

        exec ${cfg.package}/bin/coordinator start
      '';

      serviceConfig = {
        Type = "exec";
        User = "mxc";
        Group = "mxc";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/mxc" ];
      };
    };

    users.users.mxc = {
      isSystemUser = true;
      group = "mxc";
      description = "Mxc service user";
      home = "/var/lib/mxc";
      createHome = true;
    };

    users.groups.mxc = {};

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      cfg.port
      4369  # EPMD
    ] ++ (lib.range 9100 9155);  # Erlang distribution ports

    networking.firewall.allowedUDPPorts = mkIf (cfg.clusterStrategy == "gossip") [
      cfg.gossip.port
    ];
  };
}
