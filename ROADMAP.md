# mxc Roadmap

Living document. Top-to-bottom is the recommended execution order. Effort
estimates: **XS** (< 1 day), **S** (1-3 days), **M** (1-2 weeks), **L** (multi-week).

---

## Shipped

- `Mxc.Subprocess` — shared erlexec-backed runner. Argv form (execve-safe) or shell form. Deadline-based timeout, PATH resolution.
- All `System.cmd` calls in the codebase migrated to `Mxc.Subprocess`. Shell-injection surface closed in `exec_in_workload`.
- `Mxc.Agent.SystemdRunner` + behaviour + `Erlexec` and `Mock` backends. Orchestrates `create_state → set_flake → build_runner → start_unit` via the privileged `priv/bin/mxc-vm-helper`.
- `Mxc.Agent.SystemdWatcher` — polls `systemctl list-units microvm@*`, diffs state, pushes transitions to the coordinator.
- Runner config switch: `config :mxc, :microvm_runner, :systemd | :erlexec`. macOS dev defaults to `:erlexec`; Linux/NixOS prod uses `:systemd`.
- HTTP API: `GET/POST/PUT/DELETE /api/{nodes,workloads,rules}`, `GET /api/cluster/status`, bearer-token auth via `MXC_API_TOKEN`. Internal `Mxc.CLI` already consumes it.
- 181 tests passing (33 new since this work began).
- `.github/workflows/ci.yml` — tier-1 CI on `ubuntu-24.04`, all actions SHA-pinned, no Determinate Systems deps. **Green on `main`.**

---

## Phase 1 — Validate the systemd path against real systemd

**Goal:** prove the `Backend.Erlexec` path actually works. Today the SystemdRunner stack is merged but only exercised through the `Backend.Mock`. Until we run it against a real `systemctl`, every feature built on top inherits any unfound bug.

| Item | Effort | Notes | Status |
|---|---|---|---|
| `@tag :linux_systemd` integration tests | S | 8 tests in `test/mxc/agent/systemd_runner/backend/erlexec_test.exs` covering create_state, set_flake, start_unit/unit_status, stop_unit, list_units against a stub `microvm@.service` unit. `build_runner` deliberately deferred to tier-4. | **In this PR** |
| `scripts/setup-linux-test-host.sh` | XS | Idempotent host setup: installs helper, sudoers entry, stub unit, state dir. Has `--uninstall`. | **In this PR** |
| `just test-linux` | XS | Pushes sources to a remote Linux host via rsync+SSH, runs `mix test --include linux_systemd` there. Configured via `MXC_BUILDER_HOST` env. | **In this PR** |
| `.github/workflows/linux-systemd.yml` | S | Tier-2 GHA job that runs the setup script + the tagged tests on `ubuntu-24.04`. | Follow-up PR |
| HelperPath via Nix derivation | XS | `pkgs.mxc-vm-helper` in the flake instead of expecting `/usr/local/bin/mxc-vm-helper`. | Follow-up PR |

**Done when:** `mix test --include linux_systemd` is green on linux-builder, and the linux-systemd workflow is green in GHA.

---

## Phase 2 — Lock the public API surface

**Goal:** since mxc is a *service other apps consume via API*, the API contract has to be stable before external consumers exist. Doing this work now is dramatically cheaper than doing it after consumers start depending on `/api/workloads`.

| Item | Effort | Notes |
|---|---|---|
| Version the routes (`/api/v1/...`) | XS | Rename `scope "/api"` → `scope "/api/v1"` in `lib/mxc_web/router.ex`. Update `Mxc.CLI.API` to match. |
| OpenAPI spec via `open_api_spex` | S | Generates `/api/v1/openapi.json` and serves Swagger UI. Forces the contract to be explicit and machine-readable. |
| `POST /api/v1/workloads/:id/exec` | S | HTTP wrapper around `Mxc.Coordinator.exec_in_workload/3`. Body: `{command, timeout}`. Response: `{status, stdout, exit_code}`. |
| `GET /api/v1/workloads/:id/logs` (SSE) | S | Streams `journalctl -u microvm@<id> --follow` lines via Server-Sent Events. Reuses `Mxc.Subprocess` with a streaming variant. |
| `GET /api/v1/events` (SSE) | S | Streams workload/node state changes. Hooks into the existing `Phoenix.PubSub` "fact_changes" channel. |
| Per-app tokens table + scopes | M | Replace single shared `MXC_API_TOKEN` with `tokens(id, app_name, scopes, revoked_at)`. Scopes: `workloads:read`, `workloads:write`, `nodes:read`, etc. |

**Done when:** OpenAPI is published, a non-Elixir client can hit every endpoint, the CLI uses `/v1`, and per-app tokens are in place.

---

## Phase 3 — First-class production features

**Goal:** the things that matter for an external user actually running production workloads. Most of these are gaps surfaced by the `microvm.nix` audit.

| Item | Effort | Notes | Priority |
|---|---|---|---|
| **VSOCK guest contact** | M | Allocate a CID per workload, set `microvm.vsock.cid`, replace SSH-by-derived-hostname with vsock SSH (or small Elixir vsock client). Solves the IP-discovery chicken-and-egg. | **High** |
| Diff-against-booted updates | S | Track runner path at last successful boot. On rebuild, surface "needs reboot" as a derived datalox fact for `Reactor`. Mirrors `microvm -u`. | High |
| Per-workload hypervisor | S | Move `preferred_hypervisor/0` from host-global to workload attribute. Add node-capability facts so datalox only places on nodes that support the chosen hypervisor. | Medium |
| Webhooks for state changes | M | Per-app webhook subscriptions, outbound HTTP POST when workloads transition. Push-model alternative to SSE for consumers that can't keep a long connection. | Medium |
| Volume management | M | Per-workload volume declarations, first-boot provisioning via the helper script. | Medium |
| machined registration | S | Wire `microvm.registerWithMachined = true` for `machinectl status <id>` integration. | Low |
| Coordinator-level reconciler | S | Long-period reconciliation loop (every ~5 min) that double-checks DB state vs reality on every agent. Catches drift the per-agent watcher misses. | Low |

**Done when:** an external consumer can deploy a workload via the API, hit it over vsock, see logs streaming, and trust restarts/updates are observable.

---

## Phase 4 — Real end-to-end testing (tier 4)

**Goal:** prove the whole stack works, top to bottom, by booting a real microVM. Worth doing once Phase 1-3 features are stable — earlier means chasing a moving target.

| Item | Effort | Notes |
|---|---|---|
| `checks/integration.nix` | M | NixOS test framework: spins a VM with `microvm.host.enable`, deploys mxc inside it, drives the API to deploy a real cloud-hypervisor microVM, asserts state transitions reach the coordinator. |
| `.github/workflows/integration.yml` | S | Runs `nix flake check` on `ubuntu-24.04` (KVM available since 2024). Free CI for the full stack. |

**Done when:** every PR runs the NixOS VM test and a real microVM boots cleanly under CI.

---

## Phase 5 — Polish

| Item | Effort | Notes |
|---|---|---|
| Client SDKs | varies | Generated from OpenAPI. Python first (popular for ops scripting), then TypeScript. |
| Per-workload generated flakes | M | Materialize tiny flakes under `/var/lib/microvms/<id>/source/` from workload attrs (CPU, mem, image). Decouples mxc from a single shipped flake. |
| D-Bus subscription in SystemdWatcher | S | Replace polling with `PropertiesChanged` signal subscription via `busctl`. Lower latency, lower overhead — matters past tens-of-thousands of units. |

---

## Phase 6 — Scalability (hold until you hit a wall)

These don't matter until ~50 hosts / ~2k VMs. Capture for later.

- **FactStore dirty-tracking** — only re-evaluate rules whose facts changed. Today every fact change re-evaluates everything.
- **PubSub fanout sharding** — per-region channels instead of one global "fact_changes" channel.
- **Coordinator federation** — hierarchical coordinators with per-region datalox stores, meta-scheduler that places workloads across regions.
- **Per-host VM-id namespace** — currently global UUIDs; if you ever need >65k VMs per host, cgroup naming may need shortening.

---

## Open questions / decisions to revisit

- **Helper script install path on non-NixOS hosts**: `/usr/local/bin/mxc-vm-helper` assumed. On NixOS, ship via `pkgs.mxc-vm-helper` derivation in mxc's flake (Phase 1).
- **Watcher reconciliation period**: Phase 3 includes a coordinator-level reconciler at ~5 min — that interval is a guess. Worth measuring once we have multi-host load.
- **API rate limiting**: not currently a concern, but per-app tokens (Phase 2) is the natural place to attach it when it matters.
- **Multi-tenancy isolation**: today every API caller sees every workload. If mxc ever serves multiple customers, we need tenant scoping on the schema. Defer until needed.

---

## Test infrastructure tiers (reference)

| Tier | Where it runs | What it covers |
|---|---|---|
| 1 — Pure logic | macOS, Linux, CI (today) | All Elixir code through the `Mock` backend. Argv construction, state parsing, transition diffing. |
| 2 — Real systemd, no KVM | linux-builder + GHA `ubuntu-24.04` (Phase 1) | Real `systemctl` against a stub unit template. Orchestration path end-to-end except VM boot. |
| 3 — `microvm.host` enabled | Linux host with the module wired up (Phase 1+) | Helper script + sudoers + `/var/lib/microvms` paths. Still no actual KVM. |
| 4 — Real microVM boot | GHA `ubuntu-24.04` (has `/dev/kvm`) or baremetal (Phase 4) | NixOS VM test: full path including cloud-hypervisor boot. |

---

## Architectural decisions (reference)

1. **Privilege model**: agent runs as the `microvm` user with passwordless sudo for a single helper binary. Narrowest blast radius without going full setuid.
2. **Unit naming**: `microvm@<workload-uuid>.service` — uses `workload.id` directly. Globally unique, no extra schema.
3. **Flake source**: workloads point to mxc's own flake (`workload.command` is a nixosConfiguration name). Per-workload generated flakes are Phase 5.
4. **Runner migration**: new `SystemdRunner` module alongside the existing `Mxc.Agent.MicroVM` (erlexec-supervised). Config switch picks at runtime.
5. **Service, not library**: mxc is a standalone application that other apps consume via the HTTP API. Library-style embedding would couple consumers' deploys to mxc's release cycle.
6. **mxc on top of systemd, not deferring to it**: `SystemdWatcher` observes state, `Reactor` reacts at cluster level. systemd is a local actuator; mxc remains the brain.

---

## Memory references

User's auto-memory at `~/.claude/projects/-Users-samrose-mxc/memory/MEMORY.md` has broader mxc/datalox project context.
