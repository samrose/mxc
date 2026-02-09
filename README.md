# Mxc

Elixir/OTP infrastructure orchestrator that coordinates and executes workloads across a distributed cluster of agents. Uses a coordinator-agent architecture where the coordinator schedules workloads and agents execute them, either as system processes or inside microVMs.

## Architecture

Mxc runs in three modes:

- **Coordinator** — Manages the cluster, schedules workloads, serves the web UI and REST API. Requires PostgreSQL.
- **Agent** — Connects to the coordinator, reports health/resources, executes workloads. No database needed.
- **Standalone** — Runs both coordinator and agent in one process. Default for development.

Nodes discover each other via one of four clustering strategies: PostgreSQL (libcluster_postgres), gossip (multicast), DNS, or EPMD (manual).

```
┌─────────────────────────────────────────┐
│              Coordinator                │
│  ┌───────────┐  ┌──────────┐  ┌──────┐ │
│  │ Scheduler │  │ Node Mgr │  │ Web  │ │
│  └───────────┘  └──────────┘  │ UI + │ │
│        │              │       │ API  │ │
│        └──────┬───────┘       └──────┘ │
│               │                         │
│          PostgreSQL                     │
└───────────────┬─────────────────────────┘
                │ Erlang distribution
       ┌────────┼────────┐
       │        │        │
   ┌───┴──┐ ┌──┴───┐ ┌──┴───┐
   │Agent1│ │Agent2│ │Agent3│
   │ exec │ │  VM  │ │ exec │
   └──────┘ └──────┘ └──────┘
```

### Web UI & API

The coordinator serves a Phoenix LiveView dashboard at `http://localhost:4000` with real-time views for cluster status, nodes, and workloads.

REST API endpoints:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/nodes` | List all connected nodes |
| GET | `/api/nodes/:id` | Get node details |
| GET | `/api/workloads` | List all workloads |
| POST | `/api/workloads` | Create a workload |
| GET | `/api/workloads/:id` | Get workload details |
| POST | `/api/workloads/:id/stop` | Stop a workload |
| GET | `/api/cluster/status` | Cluster health status |

In development, `/dev/dashboard` provides the Phoenix LiveDashboard for BEAM metrics and `/dev/mailbox` shows the Swoosh email preview.

## Prerequisites

### With Nix (recommended)

If you have [Nix](https://nixos.org/download) with flakes enabled, everything is provided:

```bash
nix develop
```

This gives you Elixir 1.17, Erlang/OTP 27, PostgreSQL 16, Node.js 20, just, and platform-appropriate tools (QEMU, vfkit on macOS; QEMU, cloud-hypervisor, inotify-tools on Linux).

### Without Nix

Install manually:

- **Elixir** >= 1.15 (1.17 recommended)
- **Erlang/OTP** 27
- **PostgreSQL** 16
- **Node.js** 20 (for asset compilation)
- **just** (command runner) — `brew install just` on macOS

Optional, for microVM support:
- **QEMU** — `brew install qemu`
- **vfkit** (macOS) — `brew install vfkit`

## Local Development (macOS)

### 1. Enter the dev environment

```bash
# With Nix:
nix develop

# Without Nix, ensure Elixir/Erlang/PostgreSQL/Node.js are on your PATH.
```

### 2. Initialize and start PostgreSQL

First time only:
```bash
just pg-init
```

Then start it (do this each session):
```bash
just pg-start
```

This starts a local PostgreSQL instance using `.postgres/data` in the project directory, creates the `mxc` superuser, and creates `mxc_dev` and `mxc_test` databases. No system-level PostgreSQL installation is modified.

### 3. Set up the project

```bash
just setup
```

This runs `mix deps.get`, creates the database schema, and builds CSS/JS assets.

### 4. Run the server

**Standalone mode** (coordinator + agent in one process, default):
```bash
just dev
```

Visit [http://localhost:4000](http://localhost:4000) for the web UI.

**Coordinator only** (with Erlang distribution enabled):
```bash
just coordinator
```

**Agent only** (connects to a running coordinator):
```bash
just agent
# or with a custom coordinator URL:
just agent http://coordinator-host:4000
```

**Multi-agent local cluster** (start coordinator + N agents):
```bash
# Terminal 1:
just coordinator

# Terminal 2: start 3 local agents
just agents 3
```

**Local coordinator + agent cluster** (single command):
```bash
just cluster-local
```

### 5. Run tests

```bash
just test

# With coverage:
just test-coverage

# Specific file:
just test-file test/mxc_web/controllers/page_controller_test.exs
```

### 6. Code quality

```bash
# Format, compile with warnings-as-errors, and test:
just precommit

# Individual checks:
just format
just format-check
just check
```

## Building Releases

Build Elixir releases for production deployment:

```bash
# Build all three (CLI, coordinator, agent):
just build-all

# Or individually:
just build-coordinator   # -> _build/prod/rel/coordinator/
just build-agent         # -> _build/prod/rel/agent/
just build-cli           # -> ./mxc (escript binary)
```

With Nix:
```bash
nix build .#coordinator
nix build .#agent
nix build .#cli
```

## Production Deployment (Bare Metal)

### Option A: Elixir releases (any Linux)

#### Coordinator host

1. Install Erlang/OTP 27 and PostgreSQL 16.

2. Create the database:
   ```bash
   createuser mxc
   createdb mxc -O mxc
   ```

3. Generate secrets:
   ```bash
   # Phoenix secret key:
   mix phx.gen.secret
   # Erlang cookie (shared across all nodes):
   openssl rand -base64 32
   ```

4. Build the coordinator release:
   ```bash
   MIX_ENV=prod mix assets.deploy
   MIX_ENV=prod mix release coordinator --overwrite
   ```

5. Run the coordinator:
   ```bash
   DATABASE_URL="ecto://mxc:password@localhost/mxc" \
   SECRET_KEY_BASE="your-generated-secret" \
   PHX_HOST="coordinator.example.com" \
   PHX_SERVER=true \
   MXC_MODE=coordinator \
   MXC_CLUSTER_STRATEGY=postgres \
   RELEASE_COOKIE="your-erlang-cookie" \
   _build/prod/rel/coordinator/bin/coordinator start
   ```

   Or use `start_iex` instead of `start` for an interactive shell.

#### Agent hosts

1. Install Erlang/OTP 27.

2. Build the agent release:
   ```bash
   MIX_ENV=prod mix release agent --overwrite
   ```

3. Run the agent:
   ```bash
   MXC_MODE=agent \
   MXC_CLUSTER_STRATEGY=postgres \
   DATABASE_HOST=coordinator-db-host \
   DATABASE_PORT=5432 \
   DATABASE_USER=mxc \
   DATABASE_PASSWORD=password \
   DATABASE_NAME=mxc \
   RELEASE_COOKIE="your-erlang-cookie" \
   _build/prod/rel/agent/bin/agent start
   ```

   For hypervisor-backed workloads, also set:
   ```bash
   MXC_HYPERVISOR=qemu          # or cloud-hypervisor
   MXC_AGENT_CPU=4              # cores for workloads (0 = auto-detect)
   MXC_AGENT_MEMORY=8192        # MB for workloads (0 = auto-detect)
   ```

### Option B: NixOS modules (NixOS hosts)

The project provides NixOS modules for declarative deployment. Add the flake to your system configuration:

```nix
# flake.nix of your NixOS config
{
  inputs.mxc.url = "github:yourorg/mxc";

  outputs = { self, nixpkgs, mxc, ... }: {
    nixosConfigurations.coordinator-host = nixpkgs.lib.nixosSystem {
      modules = [
        mxc.nixosModules.coordinator
        mxc.nixosModules.postgres
        ./hardware-configuration.nix
        ({ pkgs, ... }: {
          # PostgreSQL
          services.mxc.postgres = {
            enable = true;
            databases = [ "mxc" ];
            users.mxc = {
              passwordFile = "/run/secrets/mxc-db-password";
              databases = [ "mxc" ];
            };
          };

          # Coordinator
          services.mxc.coordinator = {
            enable = true;
            package = mxc.packages.${pkgs.system}.coordinator;
            port = 4000;
            clusterStrategy = "postgres";
            schedulerStrategy = "spread";
            database = {
              host = "localhost";
              name = "mxc";
              user = "mxc";
              passwordFile = "/run/secrets/mxc-db-password";
            };
            secretKeyBaseFile = "/run/secrets/mxc-secret-key";
            erlangCookieFile = "/run/secrets/mxc-erlang-cookie";
          };
        })
      ];
    };

    nixosConfigurations.agent-host = nixpkgs.lib.nixosSystem {
      modules = [
        mxc.nixosModules.agent
        ./hardware-configuration.nix
        ({ pkgs, ... }: {
          services.mxc.agent = {
            enable = true;
            package = mxc.packages.${pkgs.system}.agent;
            clusterStrategy = "postgres";
            database = {
              host = "coordinator-db-host";
              name = "mxc";
              user = "mxc";
              passwordFile = "/run/secrets/mxc-db-password";
            };
            erlangCookieFile = "/run/secrets/mxc-erlang-cookie";
            hypervisor = "cloud-hypervisor";
            resources = {
              cpuCores = 8;
              memoryMB = 16384;
            };
          };
        })
      ];
    };
  };
}
```

The NixOS modules handle systemd services, firewall rules (ports 4000, 4369, 9100-9155), user creation, and security hardening automatically. The coordinator runs as an unprivileged `mxc` user; agents run as root (required for hypervisor access).

### Option C: MicroVMs (lightweight isolation)

Agents can run inside lightweight NixOS microVMs using QEMU, cloud-hypervisor, or vfkit:

```bash
# Build and run an agent VM (auto-detects architecture):
just vm-build-agent
just vm-run-agent

# Or all-in-one:
just vm-agent-test

# See all VM commands:
just vm-info
```

The agent VM connects to the host coordinator at `10.0.2.2` (QEMU user-mode NAT). Port forwards: SSH (2222), API (4001), EPMD (4370), Erlang distribution (9200-9210).

## Cluster Strategies

Configure how nodes discover each other with `MXC_CLUSTER_STRATEGY`:

| Strategy | Env Var | Use Case |
|----------|---------|----------|
| `postgres` | `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_NAME` | Production. Nodes heartbeat via a shared PostgreSQL table. Reliable, no multicast needed. |
| `gossip` | `MXC_GOSSIP_PORT` (default 45892), `MXC_GOSSIP_SECRET` | LAN clusters. UDP multicast discovery. Simple but requires multicast support. |
| `dns` | `MXC_DNS_QUERY` (e.g. `mxc.local`) | Cloud/container environments with DNS service discovery. |
| `epmd` | `MXC_CLUSTER_HOSTS` (comma-separated, e.g. `node1@host1,node2@host2`) | Manual. Specify exact node names. Good for small, static clusters. |

The default for development is `gossip`. Production recommends `postgres`.

## Environment Variables Reference

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `MXC_MODE` | `standalone` | `coordinator`, `agent`, or `standalone` |
| `MXC_UI_ENABLED` | `true` | Enable/disable web UI (coordinator only) |
| `MXC_CLUSTER_STRATEGY` | `gossip` | `postgres`, `gossip`, `dns`, or `epmd` |
| `MXC_SCHEDULER_STRATEGY` | `spread` | `spread` (distribute) or `pack` (bin-pack) |

### Database

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | Full Ecto URL (production, e.g. `ecto://user:pass@host/db`) |
| `DATABASE_HOST` | `localhost` | PostgreSQL host |
| `DATABASE_PORT` | `5432` | PostgreSQL port |
| `DATABASE_USER` | `mxc` | PostgreSQL user |
| `DATABASE_PASSWORD` | — | PostgreSQL password |
| `DATABASE_NAME` | `mxc` | Database name |
| `POOL_SIZE` | `10` | Connection pool size |

### Phoenix/Web

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listen port |
| `PHX_SERVER` | — | Set to `true` to enable the HTTP server in releases |
| `PHX_HOST` | `example.com` | Hostname for URL generation |
| `SECRET_KEY_BASE` | — | Required in production. Generate with `mix phx.gen.secret` |

### Agent

| Variable | Default | Description |
|----------|---------|-------------|
| `MXC_AGENT_CPU` | `0` (auto) | CPU cores available for workloads |
| `MXC_AGENT_MEMORY` | `0` (auto) | Memory in MB available for workloads |
| `MXC_HYPERVISOR` | — | `qemu`, `cloud_hypervisor`, or `vfkit` |
| `MXC_COORDINATOR` | — | Coordinator URL (for agent HTTP registration) |

### Clustering

| Variable | Default | Description |
|----------|---------|-------------|
| `MXC_GOSSIP_PORT` | `45892` | UDP port for gossip multicast |
| `MXC_GOSSIP_SECRET` | — | Shared secret for gossip authentication |
| `MXC_DNS_QUERY` | — | DNS query for node discovery |
| `MXC_CLUSTER_HOSTS` | — | Comma-separated node list for EPMD strategy |

## Project Structure

```
lib/
├── mxc/
│   ├── application.ex          # OTP app — starts services based on mode
│   ├── coordinator/            # Coordinator subsystem
│   │   ├── supervisor.ex       #   Supervision tree
│   │   ├── cluster.ex          #   libcluster topology config
│   │   ├── node_manager.ex     #   Tracks connected agent nodes
│   │   ├── scheduler.ex        #   Workload placement (spread/pack)
│   │   └── workload.ex         #   Workload lifecycle management
│   ├── agent/                  # Agent subsystem
│   │   ├── supervisor.ex       #   Supervision tree
│   │   ├── executor.ex         #   Runs workloads (process or VM)
│   │   ├── health.ex           #   Health reporting to coordinator
│   │   └── vm_manager.ex       #   MicroVM orchestration
│   ├── cli/                    # CLI (escript)
│   │   ├── api.ex              #   HTTP client for coordinator API
│   │   ├── output.ex           #   Terminal formatting
│   │   └── commands/           #   Subcommands (workloads, nodes, cluster)
│   └── repo.ex                 # Ecto PostgreSQL repo
├── mxc_web/
│   ├── router.ex               # Routes (browser + API)
│   ├── endpoint.ex             # Phoenix endpoint
│   ├── controllers/api/        # JSON API controllers
│   └── live/                   # LiveView pages (dashboard, nodes, workloads)
config/
├── config.exs                  # Base config
├── dev.exs                     # Development overrides
├── prod.exs                    # Production overrides
├── test.exs                    # Test overrides
└── runtime.exs                 # Runtime env var config
nix/
├── packages/                   # Nix derivations (coordinator, agent, cli)
├── modules/                    # NixOS service modules (coordinator, agent, postgres)
└── microvms/                   # MicroVM configurations (base, agent, workload-example)
```

## CLI

Build the CLI escript:

```bash
just build-cli
# -> ./mxc
```

Usage:

```bash
./mxc nodes list                    # List cluster nodes
./mxc workloads list                # List workloads
./mxc workloads create <spec>       # Create a workload
./mxc workloads stop <id>           # Stop a workload
./mxc cluster status                # Show cluster status
```

The CLI talks to the coordinator's REST API. Set `MXC_COORDINATOR` to point it at a non-default coordinator URL.

## Useful Commands

```bash
just --list          # Show all available commands
just docs            # Generate ExDoc documentation
just docs-open       # Generate and open docs in browser
just clean           # Clean build artifacts
just clean-all       # Clean everything including postgres data
just pg-stop         # Stop local PostgreSQL
just pg-reset        # Drop and recreate local PostgreSQL
just db-migrate      # Run pending migrations
just db-reset        # Drop and recreate database schema
```
