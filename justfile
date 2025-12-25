# Mxc Development Commands
# Run `just --list` to see all available commands

# Default command
default:
    @just --list

# ============================================================================
# Development
# ============================================================================

# Install dependencies
deps:
    mix deps.get

# Set up the project (deps, db, assets)
setup: deps
    mix ecto.setup
    mix assets.setup
    mix assets.build

# Run the coordinator in dev mode
coord-dev:
    MXC_MODE=standalone iex -S mix phx.server

# Run standalone mode (coordinator + agent)
dev:
    iex -S mix phx.server

# Run as coordinator only (with Erlang distribution for clustering)
coordinator:
    MXC_MODE=coordinator MXC_CLUSTER_STRATEGY=postgres iex --sname coordinator --cookie mxc-cluster-cookie -S mix phx.server

# Run as agent only (connects to coordinator)
agent coordinator_url="http://localhost:4000":
    MXC_MODE=agent MXC_COORDINATOR={{coordinator_url}} iex --sname agent --cookie mxc-cluster-cookie -S mix

# ============================================================================
# Database
# ============================================================================

# Initialize local postgres (first time only)
pg-init:
    mkdir -p .postgres
    initdb -D .postgres/data
    echo "unix_socket_directories = '$PWD/.postgres'" >> .postgres/data/postgresql.conf
    echo "listen_addresses = 'localhost'" >> .postgres/data/postgresql.conf
    echo "port = 5432" >> .postgres/data/postgresql.conf
    # Allow TCP connections from localhost (needed for VM via QEMU user-mode NAT)
    echo "host all all 127.0.0.1/32 trust" >> .postgres/data/pg_hba.conf

# Start local postgres
pg-start:
    pg_ctl -D .postgres/data -l .postgres/log start
    sleep 2
    createuser -h .postgres mxc --superuser 2>/dev/null || true
    createdb -h .postgres mxc_dev -O mxc 2>/dev/null || true
    createdb -h .postgres mxc_test -O mxc 2>/dev/null || true

# Stop local postgres
pg-stop:
    pg_ctl -D .postgres/data stop

# Reset postgres (drop and recreate)
pg-reset: pg-stop
    rm -rf .postgres/data
    just pg-init
    just pg-start

# Run database migrations
db-migrate:
    mix ecto.migrate

# Reset database
db-reset:
    mix ecto.reset

# ============================================================================
# Testing
# ============================================================================

# Run all tests
test:
    mix test

# Run tests with coverage
test-coverage:
    mix test --cover

# Run a specific test file
test-file file:
    mix test {{file}}

# ============================================================================
# Code Quality
# ============================================================================

# Format code
format:
    mix format

# Check formatting
format-check:
    mix format --check-formatted

# Run dialyzer
dialyzer:
    mix dialyzer

# Run all checks (format, compile warnings, tests)
check: format-check
    mix compile --warnings-as-errors
    mix test

# Precommit check
precommit:
    mix precommit

# ============================================================================
# Building
# ============================================================================

# Build CLI escript
build-cli:
    mix escript.build

# Build coordinator release
build-coordinator:
    MIX_ENV=prod mix assets.deploy
    MIX_ENV=prod mix release coordinator --overwrite

# Build agent release
build-agent:
    MIX_ENV=prod mix release agent --overwrite

# Build all releases
build-all: build-cli build-coordinator build-agent

# Build assets for production
build-assets:
    mix assets.deploy

# ============================================================================
# Running Releases
# ============================================================================

# Run coordinator release (production mode)
run-coordinator: build-coordinator
    _build/prod/rel/coordinator/bin/coordinator start

# Run coordinator release in foreground
run-coordinator-fg: build-coordinator
    _build/prod/rel/coordinator/bin/coordinator start_iex

# Run agent release (production mode)
run-agent: build-agent
    _build/prod/rel/agent/bin/agent start

# Run agent release in foreground
run-agent-fg: build-agent
    _build/prod/rel/agent/bin/agent start_iex

# ============================================================================
# Nix
# ============================================================================

# Enter nix development shell
shell:
    nix develop

# Run nix flake checks
nix-check:
    nix flake check

# Build coordinator package with nix
nix-build-coordinator:
    nix build .#coordinator

# Build agent package with nix
nix-build-agent:
    nix build .#agent

# Build CLI package with nix
nix-build-cli:
    nix build .#cli

# ============================================================================
# MicroVM Management
# ============================================================================

# Detect architecture and return appropriate VM config name
@_vm-arch:
    #!/usr/bin/env bash
    case "$(uname -m)" in
        arm64|aarch64) echo "aarch64" ;;
        x86_64|amd64) echo "x86_64" ;;
        *) echo "x86_64" ;;
    esac

# Build microVM image for current architecture
vm-build hypervisor="qemu":
    #!/usr/bin/env bash
    ARCH=$(just _vm-arch)
    echo "Building mxc-vm-${ARCH} with {{hypervisor}}..."
    nix build ".#nixosConfigurations.mxc-vm-${ARCH}.config.microvm.runner.{{hypervisor}}" -o result-vm
    echo "VM runner built: ./result-vm/bin/microvm-run"

# Build workload example VM for current architecture
vm-build-workload hypervisor="qemu":
    #!/usr/bin/env bash
    ARCH=$(just _vm-arch)
    echo "Building mxc-vm-workload-${ARCH} with {{hypervisor}}..."
    nix build ".#nixosConfigurations.mxc-vm-workload-${ARCH}.config.microvm.runner.{{hypervisor}}" -o result-vm-workload
    echo "VM runner built: ./result-vm-workload/bin/microvm-run"

# Run the built microVM
vm-run:
    #!/usr/bin/env bash
    if [ ! -L result-vm ]; then
        echo "No VM built. Run 'just vm-build' first."
        exit 1
    fi
    echo "Starting microVM (Ctrl+C to stop)..."
    ./result-vm/bin/microvm-run

# Run the workload example VM
vm-run-workload:
    #!/usr/bin/env bash
    if [ ! -L result-vm-workload ]; then
        echo "No workload VM built. Run 'just vm-build-workload' first."
        exit 1
    fi
    echo "Starting workload microVM (Ctrl+C to stop)..."
    ./result-vm-workload/bin/microvm-run

# Build and run VM in one command
vm-test: vm-build vm-run

# Build agent VM (includes mxc agent service)
vm-build-agent hypervisor="qemu":
    #!/usr/bin/env bash
    ARCH=$(just _vm-arch)
    echo "Building mxc-agent-${ARCH} with {{hypervisor}}..."
    nix build ".#nixosConfigurations.mxc-agent-${ARCH}.config.microvm.runner.{{hypervisor}}" -o result-vm-agent
    echo "Agent VM runner built: ./result-vm-agent/bin/microvm-run"

# Run agent VM (connects to coordinator on host)
vm-run-agent:
    #!/usr/bin/env bash
    if [ ! -L result-vm-agent ]; then
        echo "No agent VM built. Run 'just vm-build-agent' first."
        exit 1
    fi
    echo "Starting agent microVM..."
    echo "Agent will connect to coordinator at 10.0.2.2 (host)"
    echo "Make sure coordinator is running: just coordinator"
    ./result-vm-agent/bin/microvm-run

# Run multiple local agents (for testing clustering)
agents count="3":
    #!/usr/bin/env bash
    echo "Starting {{count}} local agents..."
    for i in $(seq 1 {{count}}); do
        echo "Starting agent$i..."
        MXC_MODE=agent MXC_CLUSTER_STRATEGY=postgres \
            elixir --sname "agent$i" --cookie mxc-cluster-cookie \
            -S mix run --no-halt &
        sleep 1
    done
    echo "Started {{count}} agents. Press Ctrl+C to stop all."
    wait

# Full workflow: build agent release, build agent VM, run it
vm-agent-test: build-agent vm-build-agent vm-run-agent

# Show VM build info
vm-info:
    #!/usr/bin/env bash
    ARCH=$(just _vm-arch)
    echo "Architecture: ${ARCH}"
    echo "Available VM configurations:"
    echo "  - mxc-vm-${ARCH} (base)"
    echo "  - mxc-vm-workload-${ARCH} (with nginx)"
    echo "  - mxc-agent-${ARCH} (with mxc agent service)"
    echo ""
    echo "Hypervisors: qemu (default), vfkit (macOS)"
    echo ""
    echo "Commands:"
    echo "  just vm-build              - Build base VM"
    echo "  just vm-build-workload     - Build workload VM"
    echo "  just vm-build-agent        - Build agent VM"
    echo "  just vm-run                - Run base VM"
    echo "  just vm-run-agent          - Run agent VM"
    echo "  just vm-agent-test         - Build agent + VM and run"
    echo ""
    echo "Typical workflow:"
    echo "  Terminal 1: just coordinator     # Start coordinator on host"
    echo "  Terminal 2: just vm-agent-test   # Build and run agent VM"

# ============================================================================
# Cluster Testing
# ============================================================================

# Start a local cluster with one coordinator and one agent
cluster-local:
    #!/usr/bin/env bash
    echo "Starting coordinator..."
    MXC_MODE=coordinator PORT=4000 elixir --sname coordinator -S mix phx.server &
    COORD_PID=$!
    sleep 3
    echo "Starting agent..."
    MXC_MODE=agent PORT=4001 MXC_CLUSTER_HOSTS=coordinator@$(hostname -s) elixir --sname agent -S mix run --no-halt &
    AGENT_PID=$!
    echo "Cluster running. Press Ctrl+C to stop."
    trap "kill $COORD_PID $AGENT_PID 2>/dev/null" EXIT
    wait

# ============================================================================
# Documentation
# ============================================================================

# Generate documentation
docs:
    mix docs

# Open documentation in browser
docs-open: docs
    open doc/index.html

# ============================================================================
# Cleaning
# ============================================================================

# Clean build artifacts
clean:
    mix clean
    rm -rf _build deps

# Clean everything including postgres data
clean-all: clean
    rm -rf .postgres .mix .hex priv/static/assets
