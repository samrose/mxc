# mxc Roadmap

Living document. Update as work progresses.

## Where we are (branch: `feat/exec-in-workload`)

### Done

- **`Mxc.Subprocess`** — shared erlexec-backed subprocess runner. Argv lists for execve-safe calls, charlist for shell-style. Deadline-based timeout with kill-on-deadline. PATH resolution for bare argv[0]. 9 tests passing. (`lib/mxc/subprocess.ex`, `test/mxc/subprocess_test.exs`)
- **Coordinator `exec_in_workload/3`** — refactored to use `Mxc.Subprocess`. argv list for microvm/ssh path (closes shell-injection surface from `derive_hostname/1`). 11 tests passing.
- **Executor `exec_in_workload/3`** — same refactor applied; dropped duplicate `run_shell_command`/`escape_shell_arg`/`derive_hostname` helpers.
- **MicroVM `nix build`** — `do_build_runner/3` now uses `Mxc.Subprocess` (15-min timeout, `:cd`+`:env` passthrough via `:exec_opts`).

### In flight (this PR — `feat/exec-in-workload`)

- [x] **Health sysctl** — swapped to `Mxc.Subprocess.run/2` (argv form).
- [x] **`Mxc.Agent.SystemdRunner.Backend` behaviour** + `Erlexec` (real) and `Mock` (test) impls. Mock records calls in an Agent, returns canned responses.
- [x] **`Mxc.Agent.SystemdRunner`** — orchestrates create/build/start/stop/status against a backend. Writes `/var/lib/microvms/<workload-id>/{current,flake}`, invokes `microvm@<workload-id>.service`.
- [x] **`priv/bin/mxc-vm-helper`** — privileged shell helper invoked via passwordless sudo. Subcommands: `init`, `set-flake`, `build`, `start`, `stop`, `restart`, `status`, `list`.
- [x] **Sudoers entry** — documented in `Mxc.Agent.SystemdRunner.Backend.Erlexec` moduledoc:
  ```
  microvm ALL=(root) NOPASSWD: /usr/local/bin/mxc-vm-helper
  ```
- [x] **`Mxc.Agent.SystemdWatcher` GenServer** — polls backend's `list_units/0`, diffs against last-seen, pushes transitions to the Coordinator via `update_workload/2` (or `:rpc` in agent mode). Defensive against non-UUID unit names.
- [x] **Runner config switch** — `config :mxc, :microvm_runner, :systemd | :erlexec` (default `:erlexec`). Executor dispatches microvm-type starts to the chosen runner.
- [x] **Tests with Mock backend** — 24 new tests exercise SystemdRunner state machine + Watcher diff/poll loop. All pass on macOS.
- [ ] **`@tag :linux_systemd` tier-2 scaffold** — a couple of real-systemctl tests using a stub unit template. Skipped unless `MIX_RUN_LINUX_TESTS=1`. **Deferred to follow-up PR** — needs the linux-builder integration first.
- [ ] **Verify** — full `mix test` green (✓ 181/181 passing); commit cohesive changeset.

### Architectural decisions made

1. **Privilege model**: agent runs as the `microvm` user with passwordless sudo for a single helper binary (`/usr/local/bin/mxc-vm-helper`). Narrowest blast radius without going full setuid.
2. **Unit naming**: `microvm@<workload-uuid>.service` — uses `workload.id` directly. Globally unique, no extra schema, ugly-but-stable.
3. **Flake source**: workloads point to mxc's own flake (`workload.command` is a nixosConfiguration name in `flake.nix`). Per-workload generated flakes are a follow-up if needed.
4. **Migration**: new `SystemdRunner` module alongside the existing `Mxc.Agent.MicroVM` (erlexec-supervised). Config switch picks at runtime. macOS dev keeps using `:erlexec`; Linux/NixOS prod uses `:systemd`.
5. **mxc still orchestrates on top of systemd** — not "fire and forget." `SystemdWatcher` observes state changes; `Reactor` reacts at the cluster level. systemd is a local actuator; mxc is the brain.

### Test infrastructure tiers

| Tier | Where it runs | What it covers |
|---|---|---|
| 1 — Pure logic | Anywhere (macOS, CI, Linux) | All Elixir code through the Mock backend. Argv construction, state parsing, transition diffing. |
| 2 — Real systemd, no KVM | Local linux-builder; later GHA `ubuntu-24.04` | Real `systemctl` against a stub unit template. The orchestration code path end-to-end except VM boot. |
| 3 — microvm.host enabled | Linux host with the module wired up | Helper script + sudoers + `/var/lib/microvms` paths. Still no actual KVM. |
| 4 — Real microVM boot | GHA `ubuntu-24.04` (has `/dev/kvm`) or baremetal | NixOS VM test: full path including cloud-hypervisor boot. |

## Follow-up PRs (not in this branch)

### Test infra

- [x] `.github/workflows/ci.yml` — GitHub Actions on `ubuntu-24.04` (x86_64) runs the tier-1 `mix test` suite via `nix develop`. Uses `cachix/install-nix-action` (no Determinate Systems) with all four actions pinned to commit SHAs. Caches Mix `deps`/`_build` via `actions/cache`; relies on the public `cache.nixos.org` + `microvm.cachix.org` substituters for the nix store (no per-run nix-store cache action). Uploads PostgreSQL logs on failure.
- [ ] `.github/workflows/linux-systemd.yml` — adds a tier-2 job that installs the helper script + sudoers entry on the runner and exercises the `@tag :linux_systemd` tests against real systemctl with a stub `mxc-vm-test@.service` unit. **Depends on writing the @tag tests first.**
- [ ] `checks/integration.nix` — NixOS VM test that boots a real microVM via SystemdRunner and asserts state transitions reach the coordinator. Tier-4. Needs `/dev/kvm` (GHA `ubuntu-24.04` provides it).
- [ ] `.github/workflows/integration.yml` — runs `nix flake check` on a KVM-enabled runner to execute the NixOS VM test. Tier-4 wrapper.
- [ ] `just test-linux` — pushes test sources to the local `nix.linux-builder` via SSH and runs `mix test --only linux_systemd` there. Local-dev counterpart to the tier-2 GHA job.

### Feature gaps from the audit (`~/.agent/diagrams/mxc-microvm-architecture.html`)

- [ ] **VSOCK guest contact** — allocate CIDs per workload, set `microvm.vsock.cid`, replace SSH-via-derived-hostname with vsock SSH. Solves IP-discovery chicken-and-egg.
- [ ] **Per-workload hypervisor** — move `preferred_hypervisor/0` from host-global to workload attribute; add node-capability constraints as datalox facts.
- [ ] **Diff-against-booted for updates** — track runner-path at last successful boot; surface "needs reboot" as a derived fact for `Reactor`.
- [ ] **Volume management** — per-workload volume declarations + first-boot provisioning via the helper script.
- [ ] **machined registration** — wire `microvm.registerWithMachined = true` for `machinectl status <id>` integration.

### Scalability work (when needed)

These don't matter until you're past ~50 hosts / ~2k VMs, but capturing for later:

- [ ] **FactStore profiling** — measure eval latency under load; add dirty-tracking so only rules whose facts changed re-evaluate.
- [ ] **PubSub fanout sharding** — per-region channels instead of one global channel.
- [ ] **Coordinator federation** — hierarchical coordinators, per-region datalox stores, meta-scheduler that places workloads across regions.
- [ ] **Per-host VM-id namespace** — currently global UUIDs; if you ever need >65k VMs per host the cgroup naming may need shortening.

## Open questions

- **Helper script install path**: `/usr/local/bin/mxc-vm-helper` assumed. On NixOS, should this come from a `pkgs.mxc-vm-helper` derivation in mxc's own flake? (Yes, eventually.)
- **D-Bus vs polling**: SystemdWatcher polls by default. D-Bus subscription is lower-latency and lower-overhead but requires a dbus library or shelling out to `busctl`. Polling at 2s intervals is fine for tens-of-thousands-of-VMs; D-Bus matters past that. Defer.
- **Watcher placement**: SystemdWatcher is per-agent (each agent host watches its own systemd). Should there also be a coordinator-level reconciler that double-checks DB state vs reality on a longer timescale? Probably yes, but later.

## Memory references

See user's auto-memory at `~/.claude/projects/-Users-samrose-mxc/memory/MEMORY.md` for the broader mxc/datalox project context.
