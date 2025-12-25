# PostgreSQL NixOS module for Mxc
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.mxc.postgres;
in {
  options.services.mxc.postgres = {
    enable = mkEnableOption "PostgreSQL for Mxc";

    port = mkOption {
      type = types.port;
      default = 5432;
    };

    databases = mkOption {
      type = types.listOf types.str;
      default = [ "mxc" ];
      description = "Databases to create";
    };

    users = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          passwordFile = mkOption {
            type = types.path;
            description = "File containing password";
          };
          databases = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Databases this user can access";
          };
        };
      });
      default = {};
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1/32" "::1/128" ];
      description = "Networks allowed to connect";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/postgresql/${config.services.postgresql.package.psqlSchema}";
      description = "PostgreSQL data directory";
    };
  };

  config = mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      port = cfg.port;
      dataDir = cfg.dataDir;

      enableTCPIP = true;

      authentication = mkForce ''
        # Local connections
        local all all trust
        host all all 127.0.0.1/32 scram-sha-256
        host all all ::1/128 scram-sha-256
        # Configured networks
        ${concatMapStringsSep "\n" (net: "host all all ${net} scram-sha-256") cfg.allowedNetworks}
      '';

      ensureDatabases = cfg.databases;

      ensureUsers = mapAttrsToList (name: userCfg: {
        inherit name;
        ensureDBOwnership = true;
      }) cfg.users;

      settings = {
        listen_addresses = "*";
        max_connections = 200;

        # Logging
        log_destination = "stderr";
        logging_collector = true;
        log_directory = "log";
        log_filename = "postgresql-%Y-%m-%d_%H%M%S.log";
        log_rotation_age = "1d";
        log_rotation_size = "100MB";

        # Performance
        shared_buffers = "256MB";
        effective_cache_size = "1GB";
        work_mem = "16MB";
        maintenance_work_mem = "128MB";

        # WAL
        wal_level = "replica";
        max_wal_size = "1GB";
        min_wal_size = "80MB";
      };
    };

    # Create password files and set passwords after postgres starts
    systemd.services.mxc-postgres-setup = {
      description = "Set up Mxc PostgreSQL users";
      after = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql.service" ];

      script = concatStringsSep "\n" (mapAttrsToList (name: userCfg: ''
        if [ -f "${userCfg.passwordFile}" ]; then
          PASSWORD=$(cat "${userCfg.passwordFile}")
          ${pkgs.postgresql_16}/bin/psql -U postgres -c "ALTER USER ${name} WITH PASSWORD '$PASSWORD';"
          ${concatMapStringsSep "\n" (db: ''
            ${pkgs.postgresql_16}/bin/psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${name};"
          '') userCfg.databases}
        else
          echo "Warning: Password file ${userCfg.passwordFile} not found for user ${name}"
        fi
      '') cfg.users);

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
