{
  description = "Mxc - Elixir-based infrastructure orchestration";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir/Erlang versions
        erlang = pkgs.beam.interpreters.erlang_27;
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir_1_18;

        # Common build inputs for Elixir projects
        elixirDeps = [
          elixir
          erlang
          pkgs.rebar3
        ];

      in
      {
        # Elixir packages
        packages = {
          agent = pkgs.callPackage ./nix/packages/agent.nix {
            inherit beamPackages;
          };

          coordinator = pkgs.callPackage ./nix/packages/coordinator.nix {
            inherit beamPackages;
            nodejs = pkgs.nodejs_20;
          };

          cli = pkgs.callPackage ./nix/packages/cli.nix {
            inherit beamPackages;
          };

          default = self.packages.${system}.cli;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = elixirDeps ++ (with pkgs; [
            postgresql_16
            nodejs_20  # For Phoenix assets

            # Tools
            git
            just
            jq
          ])
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.inotify-tools
            pkgs.qemu
            pkgs.cloud-hypervisor
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.fswatch
            pkgs.vfkit
            pkgs.qemu
          ];

          shellHook = ''
            # Set up local postgres for development
            export PGDATA="$PWD/.postgres/data"
            export PGHOST="$PWD/.postgres"
            export DATABASE_URL="postgresql://mxc:mxc@localhost:5432/mxc_dev"

            # Elixir config
            export MIX_HOME="$PWD/.mix"
            export HEX_HOME="$PWD/.hex"
            export ERL_AFLAGS="-kernel shell_history enabled"

            # Cluster strategy for local dev
            export MXC_CLUSTER_STRATEGY="gossip"

            # Hypervisor for VMs (vfkit on macOS, cloud-hypervisor on Linux)
            ${if pkgs.stdenv.isDarwin then ''
              export MXC_HYPERVISOR="vfkit"
            '' else ''
              export MXC_HYPERVISOR="cloud_hypervisor"
            ''}

            # Ensure hex and rebar are installed
            mix local.hex --force --if-missing
            mix local.rebar --force --if-missing

            # Install Phoenix if not present
            if ! mix archive | grep -q phx_new; then
              mix archive.install hex phx_new --force
            fi

            echo "Mxc development shell"
            echo ""
            echo "To initialize the project:"
            echo "  mix phx.new . --app mxc --module Mxc"
            echo ""
            echo "To start local postgres:"
            echo "  just pg-init   # first time only"
            echo "  just pg-start"
            echo ""
            echo "To run coordinator:"
            echo "  just coord-dev"
          '';
        };

        # Checks run by `nix flake check`
        checks = {
          # Tests will be added once project is created
        };
      }
    ) // {
      # NixOS modules (not system-specific)
      nixosModules = {
        coordinator = import ./nix/modules/coordinator.nix;
        agent = import ./nix/modules/agent.nix;
        postgres = import ./nix/modules/postgres.nix;
      };

      # MicroVM configurations for both architectures
      # Build from darwin or linux hosts
      nixosConfigurations = let
        inherit (nixpkgs) lib;

        # Host systems that can build VMs
        hostSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

        mkMicroVM = { hostSystem, guestSystem, name, extraModules ? [] }:
          lib.nixosSystem {
            system = guestSystem;
            modules = [
              microvm.nixosModules.microvm
              ./nix/microvms/base.nix
              ({ lib, ... }: {
                # Use host packages for the runner when building from darwin
                microvm.vmHostPackages = lib.mkIf (lib.hasSuffix "-darwin" hostSystem)
                  nixpkgs.legacyPackages.${hostSystem};
              })
            ] ++ extraModules;
            specialArgs = { inherit self nixpkgs; pkgs = nixpkgs.legacyPackages.${guestSystem}; };
          };
      in {
        # aarch64-linux guests (for Apple Silicon macs or aarch64-linux hosts)
        "mxc-vm-aarch64" = mkMicroVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "mxc-vm";
        };

        "mxc-vm-workload-aarch64" = mkMicroVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "mxc-vm-workload";
          extraModules = [ ./nix/microvms/workload-example.nix ];
        };

        # x86_64-linux guests (for Intel macs or x86_64-linux hosts)
        "mxc-vm-x86_64" = mkMicroVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "mxc-vm";
        };

        "mxc-vm-workload-x86_64" = mkMicroVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "mxc-vm-workload";
          extraModules = [ ./nix/microvms/workload-example.nix ];
        };

        # Agent VMs - run mxc agent connecting to host coordinator
        "mxc-agent-aarch64" = mkMicroVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "mxc-agent";
          extraModules = [ ./nix/microvms/agent.nix ];
        };

        "mxc-agent-x86_64" = mkMicroVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "mxc-agent";
          extraModules = [ ./nix/microvms/agent.nix ];
        };
      };
    };
}
