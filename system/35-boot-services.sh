#!/usr/bin/env bash
# 35-boot-services.sh — stop paying for two boot-time services this machine
# gets nothing from.
#
# Measured here before the change (`systemd-analyze`, `systemd-analyze blame`):
#
#   7.820s firmware + 5.906s loader + 5.347s kernel + 7.417s userspace = 26.491s
#     3.780s NetworkManager-wait-online.service
#     1.321s gpu-manager.service
#
# Those two are 5.1s of the 7.4s userspace phase, and neither does anything for
# a laptop with an Intel GPU.
#
#   NetworkManager-wait-online
#     Sits at the top of the critical chain: graphical.target waits on
#     network-online.target waits on this, which blocks until DHCP finishes.
#     What actually wants network-online.target here is cloud-config,
#     cloud-final, cups-browsed, docker, fwupd-refresh and whoopsie — printer
#     discovery, firmware metadata, crash reporting, and a docker that
#     system/60-docker.sh has already made socket-activated. Every one of them
#     copes with a network that shows up later, which is the normal condition
#     for a laptop that roams between networks anyway. Nothing here is worth
#     holding the login screen for.
#
#   gpu-manager
#     Ubuntu's hybrid-graphics arbiter: it exists to sort out NVIDIA Optimus and
#     switchable AMD setups. This machine has one Intel iGPU and no proprietary
#     driver, so it wakes up, finds nothing to arbitrate, and costs 1.3s.
#
# Both are `disable`, never `disable --now` and never `mask`. Disable only stops
# them being pulled in at boot; anything that genuinely needs them can still
# start them, and re-enabling is one command (printed below, and in the README).
#
# Each change is guarded by a check that this machine really is the case
# described above — see the guards inline. A machine that fails a guard keeps
# the service and logs why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

# Disable a unit iff it is enabled, matching the literal state string.
#
# NOT `systemctl is-enabled --quiet`: that also succeeds for static, indirect,
# generated and transient units, and `systemctl disable` on a static unit is a
# no-op that still prints a warning — so every run would look like it changed
# something and the idempotency contract would be quietly false.
disable_unit() { # <unit> <why>
  local unit="$1" why="$2" state
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    log "$unit is not installed — nothing to do"
    return 0
  fi
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [ "$state" != enabled ]; then
    log "$unit is already not enabled at boot (state: ${state:-unknown})"
    return 0
  fi
  log "disabling $unit — $why"
  run systemctl disable "$unit"
}

# ── NetworkManager-wait-online ───────────────────────────────────────────────
# The guard: a filesystem that must be mounted over the network genuinely does
# need the network up before local-fs/remote-fs settles. `_netdev`, nfs and cifs
# entries in fstab are the honest signal for that, and a machine with one keeps
# the wait.
if [ -r /etc/fstab ] && out_matches "$(grep -vE '^[[:space:]]*#' /etc/fstab 2>/dev/null || true)" -E '(^|[[:space:]])(nfs4?|cifs|smbfs)([[:space:]]|$)|_netdev'; then
  log "fstab has a network filesystem — keeping NetworkManager-wait-online"
else
  disable_unit NetworkManager-wait-online.service \
    "nothing here needs the network up before the login screen (saves ~3.8s)"
fi

# ── gpu-manager ──────────────────────────────────────────────────────────────
# The guard: only skip the arbiter on a machine with nothing to arbitrate. Both
# signals have to agree — a second GPU in lspci, or a proprietary/hybrid driver
# module loaded — because a discrete card that is currently powered down still
# shows up in lspci, and a driver can be loaded for hardware lspci renders
# differently across versions.
gpus="$(lspci -nn 2>/dev/null | grep -icE 'vga compatible controller|3d controller' || true)"
hybrid_drivers="$(lsmod 2>/dev/null | grep -cE '^(nvidia|nouveau|amdgpu|radeon)[[:space:]]' || true)"

if [ "${gpus:-0}" -gt 1 ] || [ "${hybrid_drivers:-0}" -gt 0 ]; then
  log "more than one GPU or a hybrid/proprietary driver is present — keeping gpu-manager"
  log "  (GPUs: ${gpus:-?}, hybrid driver modules: ${hybrid_drivers:-?})"
else
  disable_unit gpu-manager.service \
    "single Intel GPU, no proprietary driver — nothing to arbitrate (saves ~1.3s)"
fi

log "boot services reviewed. Undo either with:"
log "  sudo systemctl enable NetworkManager-wait-online.service gpu-manager.service"
log "  check the result after a reboot with:  systemd-analyze blame | head"
