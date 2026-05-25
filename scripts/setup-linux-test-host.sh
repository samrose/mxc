#!/usr/bin/env bash
# setup-linux-test-host.sh — idempotently configure a Linux host to run the
# tier-2 @tag :linux_systemd integration tests.
#
# Installs:
#   - /usr/local/bin/mxc-vm-helper            (the privileged helper)
#   - /etc/sudoers.d/mxc-vm-helper            (passwordless sudo for $USER)
#   - /etc/systemd/system/microvm@.service    (the stub unit template)
#   - /var/lib/microvms/                      (state dir, owned by $USER:kvm)
#
# Requires sudo. Safe to re-run.
#
# Usage:
#   scripts/setup-linux-test-host.sh
#   scripts/setup-linux-test-host.sh --uninstall   # remove everything

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_SRC="$REPO_ROOT/priv/bin/mxc-vm-helper"
STUB_SRC="$REPO_ROOT/priv/systemd/microvm@.service.stub"

HELPER_DST="/usr/local/bin/mxc-vm-helper"
SUDOERS_DST="/etc/sudoers.d/mxc-vm-helper"
UNIT_DST="/etc/systemd/system/microvm@.service"
STATE_DIR="/var/lib/microvms"

USER_NAME="${SUDO_USER:-${USER:-$(id -un)}}"
# Use the kvm group if present (microvm.nix convention), otherwise fall back
# to the user's primary group so this also works on plain Linux hosts.
if getent group kvm >/dev/null 2>&1; then
  GROUP_NAME="kvm"
else
  GROUP_NAME="$(id -gn "$USER_NAME")"
fi

log() { printf '[setup] %s\n' "$*"; }

uninstall() {
  log "removing helper, sudoers, stub unit, state dir"
  sudo rm -f "$HELPER_DST" "$SUDOERS_DST" "$UNIT_DST"
  sudo systemctl daemon-reload || true
  sudo rm -rf "$STATE_DIR"
  log "uninstalled"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
  exit 0
fi

# ── 1. helper ──────────────────────────────────────────────────────────
log "installing $HELPER_DST"
sudo install -m 0755 "$HELPER_SRC" "$HELPER_DST"

# ── 2. sudoers ─────────────────────────────────────────────────────────
log "configuring sudoers for $USER_NAME"
# Use visudo to validate before committing to the canonical path.
sudoers_tmp="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$HELPER_DST" > "$sudoers_tmp"
sudo visudo -cf "$sudoers_tmp" >/dev/null
sudo install -m 0440 -o root -g root "$sudoers_tmp" "$SUDOERS_DST"
rm -f "$sudoers_tmp"

# ── 3. stub unit ───────────────────────────────────────────────────────
log "installing stub microvm@.service template"
if [[ -e "$UNIT_DST" ]] && ! sudo grep -q "mxc tier-2 test stub" "$UNIT_DST"; then
  echo "[setup] WARNING: $UNIT_DST exists and is not the mxc stub." >&2
  echo "[setup] If you have a real microvm.host install, do NOT run tier-2 tests here." >&2
  echo "[setup] Aborting to avoid clobbering production config." >&2
  exit 1
fi
sudo install -m 0644 "$STUB_SRC" "$UNIT_DST"
sudo systemctl daemon-reload

# ── 4. state dir ───────────────────────────────────────────────────────
log "creating $STATE_DIR (owned by $USER_NAME:$GROUP_NAME)"
sudo install -d -o "$USER_NAME" -g "$GROUP_NAME" -m 0755 "$STATE_DIR"

# Sanity probe — make sure passwordless sudo to the helper actually works.
if ! sudo -n "$HELPER_DST" list >/dev/null 2>&1; then
  echo "[setup] ERROR: sudo -n $HELPER_DST list failed. Check sudoers entry." >&2
  exit 2
fi

log "done"
log ""
log "Run the tier-2 tests with:"
log "    nix develop -c mix test --include linux_systemd"
