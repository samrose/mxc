# Design: mxc Tier-2/3 systemd library integration tests + toolchain

- **Date:** 2026-06-08
- **Status:** Draft for review
- **Scope of this round:** Tier-2/3 only (real `systemd`, no microVM boot). Tier-4 (real boot) is documented as a follow-up lane, not built here.

---

## 1. Problem statement

mxc's `Mxc.Agent.SystemdRunner` + `Backend.Erlexec` stack is the code that orchestrates microvm.nix units via `systemd`. Today it is exercised only through `Backend.Mock` (Tier-1, 181 tests green). The real path — mxc's Elixir code driving a real `systemctl` and the privileged `mxc-vm-helper` — has **never executed successfully**. The 8 `:linux_systemd` ExUnit tests are marked "invalid" on macOS and there is no CI lane that runs them on real systemd.

Until that path runs green, every feature built on top inherits any unfound bug, and we cannot honestly claim mxc is "fit to orchestrate microvm.nix machines."

**This design closes the Tier-2/3 gap**: prove that a real Elixir consumer, using mxc **as a Nix-flake-provided library**, can drive the full unit lifecycle (`create_state → set_flake → start_unit → status → stop_unit → list_units`) against real `systemd`, short of booting a guest.

## 2. Foundational decisions (corrections to ROADMAP.md)

Two ROADMAP.md statements are reversed/upgraded by this work and the spec assumes the corrected forms:

1. **mxc is a LIBRARY, not a service** (reverses architectural decision #5). mxc is an Elixir library that other Elixir apps depend on to orchestrate microvm.nix — even though it carries heavy Nix/systemd dependencies. The HTTP API remains, but as *one consumer* of the library, not the only entry point.
2. **"HelperPath via Nix derivation" is promoted from follow-up to a core requirement.** As a library, mxc cannot assume it owns the consumer host's `/usr/local/bin` or sudoers; it must *ship* the helper and a way to wire it.

ROADMAP.md must be updated to reflect both (decision #5 rewritten; Phase-1 follow-up table adjusted).

## 3. Consumer model

mxc is delivered through two channels. **The flake-input consumer is canonical and supported; pure-Hex works but the consumer wires the host themselves.**

| Artifact | Delivery channel | Part of the importable Elixir library? |
|---|---|---|
| `Mxc.*` Elixir modules + `priv/bin/mxc-vm-helper` (script) | Hex package (`{:mxc, "~> x"}`) | **Yes** — the library proper |
| `packages.<system>.mxc-vm-helper` (derivation) | mxc flake output | No — adjacent packaging |
| `nixosModules.agentHost` | mxc flake output | No — adjacent deployment sugar |
| `checks.<system>.systemd-tier2` | mxc flake output | No — test |

**Canonical (flake-input) consumer** adds mxc as a flake input and gets both the Elixir library (as a Nix-built BEAM dependency) and the host-wiring outputs:

```nix
inputs.mxc.url = "github:samrose/mxc";
# ...
imports = [ inputs.mxc.nixosModules.agentHost ];
# helper resolved from inputs.mxc.packages.${system}.mxc-vm-helper
```

**Pure-Hex consumer** gets the Elixir modules + the `priv/bin/mxc-vm-helper` script and is responsible for satisfying the host contract (§4.2) by hand.

## 4. What "the library" owns

### 4.1 The public facade (already exists)

Consumers call only:

- `Mxc.Agent.SystemdRunner.start_workload(%Workload{type: "microvm"})` → `:ok | {:error, {stage, reason}}`
- `Mxc.Agent.SystemdRunner.stop_workload/1`
- `Mxc.Agent.SystemdRunner.status/1` → unit state atom (`:active | :inactive | :failed | :activating | :unknown`)
- `Mxc.Agent.SystemdRunner.list_units/0`
- `Mxc.Agent.SystemdRunner.unit_name/1`

`Backend.Erlexec` is internal, hidden behind `Backend.current()`. Tests assert at the facade altitude, not the backend.

### 4.2 The host contract (documented, library-owned)

The library requires the host to provide:

1. an `mxc-vm-helper` reachable at the path mxc is configured with,
2. a sudoers entry permitting the `microvm` user to run that helper as root with no password,
3. `/var/lib/microvms` writable by the `microvm` user,
4. `nix` on `PATH`.

`nixosModules.agentHost` is **one declarative way to satisfy this contract**, not the contract itself and not the library.

## 5. Toolchain components to build

### A. `pkgs.mxc-vm-helper` — Nix derivation
Wrap the existing `priv/bin/mxc-vm-helper` script into a derivation with its runtime deps (`nix`, `systemd` for `systemctl`, coreutils) on its `PATH` via `makeWrapper`. Output is a store path. Exposed as `packages.<system>.mxc-vm-helper` and consumed by component B. Replaces the `/usr/local/bin/mxc-vm-helper` host assumption.

### B. `mxc.agentHost` — NixOS module (flake output `nixosModules.agentHost`)
Options (at least): `enable`, `helperPackage` (defaults to `pkgs.mxc-vm-helper`), `user` (default `microvm`), `stateDir` (default `/var/lib/microvms`). When enabled it declaratively wires:
- the `microvm` user/group with `kvm` membership,
- `security.sudo` rule pinned to the store-path helper,
- the state directory via `systemd.tmpfiles`,
- `microvm.host.enable = true`,
- sets the mxc runtime config keys (§C) to the store paths so a consumer app inherits correct paths.

The test node and a real NixOS consumer import the **identical** module. Replaces `scripts/setup-linux-test-host.sh` (which is removed or reduced to a thin non-Nix fallback).

### C. Runtime config for host paths (code change in `Backend.Erlexec`)
Move `@helper`/`@sudo`/`@systemctl` from `Application.compile_env` to runtime `Application.get_env`. Library defaults are **library-honest**:
- helper default → `Application.app_dir(:mxc, "priv/bin/mxc-vm-helper")` (ships in the Hex artifact),
- `sudo`/`systemctl` default → resolved via `System.find_executable/1` at runtime, overridable.

The `agentHost` module overrides the helper key to point at `packages.mxc-vm-helper`. This is the concrete code change the library framing forces; it must not break the existing Mock-backed tests.

### D. "Fail fast without Nix" guard (code change)
In `Mxc.Application.start/2`, check `System.find_executable("nix")`; if absent, raise a clear, actionable error (`Mxc.Error.NixMissing` or a raise with remediation text) so the library refuses to run on a Nix-less machine. No graceful degradation. Must be guarded so it does not break Tier-1 CI / dev environments that *do* have Nix (they do — everything runs under `nix develop`). Consider a config escape hatch (`config :mxc, :require_nix, false`) used only by Tier-1 unit tests that never touch the real backend, to avoid coupling pure-logic tests to Nix presence — decision deferred to implementation, but called out here.

### E. `mxc_consumer_smoke` — minimal Nix-built consumer
A tiny escript (or `Mix.Task`-free release) in `test/support/consumer/` or a dedicated flake package that **declares mxc as a dependency** and calls only the public facade in sequence, printing structured results (e.g. JSON lines) the test driver can assert on:
1. `start_workload/1` a synthetic `%Workload{type: "microvm", id: <uuid>, command: <config_name>}`,
2. print `status/1`,
3. print `list_units/0`,
4. `stop_workload/1`,
5. print `status/1` again.

It is the stand-in for "another Elixir app." Building it at all proves mxc is consumable as a flake input; running it proves orchestration works.

## 6. The stub `microvm@.service`

Module B installs a `microvm@.service` template that does **not** boot a guest but is **real to systemd**:
- `ExecStart` runs a long-lived process (e.g. `sleep infinity`) so `systemctl is-active microvm@<id>.service` → `active`,
- a `ExecStartPre`/state hook honors the state file written by the helper's `init`/`set-flake` steps so those steps have observable effect,
- `stop` transitions it to `inactive`; `list-units microvm@*` enumerates it.

`build_runner` is stubbed to a no-op success in this tier (real `nix build` of a runner is Tier-4). This makes the facade lifecycle assertions genuinely exercised against real systemd state — nothing is faked at the systemd layer.

## 7. The test: `checks.<system>.systemd-tier2` (`pkgs.testers.nixosTest`)

One node imports `mxc.agentHost` and includes the `mxc_consumer_smoke` package. `testScript` (Python driver):

1. `node.wait_for_unit("multi-user.target")`.
2. Assert the host contract is satisfied: helper present at its configured (store) path; sudoers permits it; `/var/lib/microvms` exists and is owned by `microvm`; `nix` on PATH.
3. Run `mxc_consumer_smoke` for a synthetic workload id.
4. From the **driver side**, assert via real `systemctl`: `microvm@<id>.service` is `active`; the escript's printed `status/1` agrees (`:active`).
5. Assert `list_units/0` output (from escript) contains the id.
6. Assert after `stop_workload/1`: `systemctl is-active` → `inactive`/gone; escript's second `status/1` → `:inactive` or `:unknown`; id absent from `list_units`.
7. Negative paths:
   - `status/1` on an unknown id → `:unknown`,
   - the sudoers scoping holds: a non-permitted command via the helper user is rejected (privilege boundary test).

**Success criteria:** `nix build .#checks.<system>.systemd-tier2` realizes green, exercising every facade function against real systemd with no mocking below the facade.

## 8. CI wiring: `.github/workflows/linux-systemd.yml`

A new job (separate from the existing tier-1 `ci.yml`), `runs-on: ubuntu-latest`:
- enable L1 KVM (udev rule writing `99-kvm4all.rules` + reload),
- install Nix with `experimental-features = nix-command flakes` and `system-features = kvm nixos-test`,
- optional cachix for cache,
- `nix build .#checks.x86_64-linux.systemd-tier2 --print-build-logs`.

No nested virtualization is required (no guest boots). Blocking on PRs to `main`. A `flake-check`-style eval job may be added to assert the new outputs evaluate.

## 9. Fate of existing assets

- **The 8 `:linux_systemd` ExUnit tests** remain as direct backend unit tests, runnable via `just test-linux` against any real systemd host. They are **no longer the integration contract** — the nixosTest is. We do **not** run `mix test` inside the test node (a real consumer never does that).
- **`scripts/setup-linux-test-host.sh`** is superseded by `nixosModules.agentHost`. Either removed or reduced to a thin documented fallback for non-Nix hosts.
- **`priv/systemd/microvm@.service.stub`** evolves into the real-to-systemd stub described in §6 (installed by the module).

## 10. Tier-4 follow-up lane (documented, NOT built this round)

Real microVM boot needs **nested** KVM. GitHub shared runners give L1 KVM but do not reliably expose nested virt to the L2 guest, so the inner microvm.nix VM fails or falls back to slow TCG. The intended solution:

- Register a KVM-capable, nested-virt-enabled host as a **Nix remote builder** (`nix.buildMachines` / `/etc/nix/machines`).
- Tier-4 becomes `checks.<system>.systemd-tier4-boot`, a nixosTest whose node has `microvm.host.enable` and actually boots a real microvm.nix guest, asserting state transitions reach the coordinator.
- The same `nix build .#checks.<system>.systemd-tier4-boot` command transparently offloads realization to the builder from a developer Mac or a CI job (credentials via SSH secret). nixosTests run as part of the build, so the VM boots on the builder.

This supersedes the rsync-based `just test-linux` model for real-boot testing. Out of scope for this round beyond this description.

## 11. Out of scope (YAGNI)

Real microVM boot, nested virt, the remote-builder lane implementation, VSOCK guest contact, per-app tokens, OpenAPI, SSE endpoints. None are touched here.

## 12. Error handling

- Facade returns `{:error, {stage, reason}}`; the escript prints the stage/reason and exits non-zero so the driver fails loudly with the stage that broke.
- Helper failures (sudo denied, state dir missing) must surface as a specific `reason`, not a generic crash — the negative-path tests pin this.
- The Nix-missing guard (§D) raises with remediation text at app start.

## 13. Risks

- **Runtime-config change (§C) could regress Tier-1 tests** if defaults resolve differently under Mock. Mitigation: Mock backend ignores paths; verify all 181 tests stay green.
- **`nixosTest` evaluation cost** in CI (builds a NixOS closure). Mitigation: cachix; the node is minimal (no microvm boot).
- **Nix-missing guard coupling** (§D) breaking pure-logic CI. Mitigation: escape hatch config used by Tier-1 only.
- **erlexec NIF under a Nix-built consumer** may surface packaging issues — which is *the point*; better found here than by a real consumer.

## 14. Success definition

`nix build .#checks.x86_64-linux.systemd-tier2` is green in `.github/workflows/linux-systemd.yml`, exercising mxc's public facade end-to-end against real `systemd` through a real Nix-flake consumer, with the existing 181 Tier-1 tests still green. Phase 1's "Done when" is then satisfied for the no-boot tiers, and Tier-4 is fully specified for a follow-up.
