#!/usr/bin/env bash
# 80-nix-gpu.sh — let Nix-built GUI apps use the GPU on a non-NixOS system.
#
# The problem: a Nix package's libglvnd/Mesa looks for DRI drivers under
# /run/opengl-driver, the NixOS convention. Ubuntu has no such path — its
# drivers live in /usr/lib/x86_64-linux-gnu/dri and are not ABI-matched to the
# Nix closure anyway. So every Nix GUI app starts with no GL driver at all.
# Flutter apps (LocalSend) refuse to start outright — "No GL Implementation
# Available"; Electron apps (Brave, Discord, VS Code) quietly fall back to
# software rendering.
#
# The fix: home-manager builds a driver bundle (its own Mesa, matching the
# closure) and ships a setup script that installs a systemd unit symlinking
# /run/opengl-driver at that bundle on every boot — /run is a tmpfs, so a bare
# symlink would not survive a reboot. This script just runs that setup, because
# it needs root and the rest of dome's root work lives here.
#
# It has to run AFTER a home-manager generation exists, so install.sh calls it
# again at the end of a fresh install; `sudo make system` covers re-runs.
# Re-run it after a flake update too: the bundle's store path changes, and
# home-manager prints "GPU drivers require an update" on the next switch.
#
# With --check it only reports (exit 0 = already set up, 1 = work to do) and
# needs no root, so callers can avoid a pointless sudo prompt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  "") ;;
  *) die "usage: 80-nix-gpu.sh [--check]" ;;
esac

[ "$CHECK_ONLY" = 1 ] || require_root

GPU_USER="$(target_user 2>/dev/null || true)"
if [ -z "$GPU_USER" ]; then
  warn "cannot determine the target user — skipping the Nix GPU setup"
  exit 0
fi
if ! id "$GPU_USER" >/dev/null 2>&1; then
  warn "configured user '$GPU_USER' does not exist here — skipping the Nix GPU setup"
  exit 0
fi
USER_HOME="$(getent passwd "$GPU_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] || { warn "no home directory for $GPU_USER — skipping"; exit 0; }

# The activation script of the CURRENT generation names both paths we need, so
# this follows home-manager automatically instead of pinning a store hash.
ACTIVATE=""
for candidate in \
  "$USER_HOME/.local/state/home-manager/gcroots/current-home/activate" \
  "/nix/var/nix/profiles/per-user/$GPU_USER/home-manager/activate"; do
  if [ -r "$candidate" ]; then
    ACTIVATE="$candidate"
    break
  fi
done
if [ -z "$ACTIVATE" ]; then
  log "no home-manager generation for $GPU_USER yet — skipping (install.sh re-runs this after the user layer)"
  exit 0
fi

# Both matches are anchored to /nix/store and to the exact file name, so this
# can only ever execute a store path — not something writable by the user.
SETUP="$(grep -oE '/nix/store/[a-z0-9]+-non-nixos-gpu/bin/non-nixos-gpu-setup' "$ACTIVATE" | head -n1 || true)"
WANT="$(sed -nE 's|^new=(/nix/store/[a-z0-9]+-non-nixos-gpu)$|\1|p' "$ACTIVATE" | head -n1 || true)"

if [ -z "$SETUP" ] || [ ! -x "$SETUP" ]; then
  log "this home-manager version does not ship the non-NixOS GPU setup — nothing to do"
  exit 0
fi

HAVE="$(readlink /run/opengl-driver 2>/dev/null || true)"
if [ -n "$WANT" ] && [ "$HAVE" = "$WANT" ]; then
  log "Nix GPU drivers already set up: /run/opengl-driver -> $WANT"
  exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
  log "Nix GPU drivers need setting up"
  exit 1
fi

if [ -n "$HAVE" ]; then
  log "updating Nix GPU drivers (was: $HAVE)"
else
  log "setting up Nix GPU drivers so Nix GUI apps can use the GPU"
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: $SETUP"
  mark_change
  exit 0
fi

# Not via run(): a GPU symlink is a nice-to-have, and this script is one of the
# last things the system layer does. Letting a failure here propagate through
# set -e would abort the whole provision over an optional step. (run() also
# swallows the exit status — it ends in mark_change — so it cannot report one.)
if "$SETUP"; then
  mark_change
else
  warn "GPU setup failed — Nix GUI apps will fall back to software rendering"
  warn "  retry with:  sudo bash system/80-nix-gpu.sh"
  exit 0
fi

if [ -e /run/opengl-driver/lib/dri ]; then
  log "/run/opengl-driver -> $(readlink /run/opengl-driver)"
  log "restart any Nix GUI app that was already running to pick it up"
else
  warn "setup ran but /run/opengl-driver is still missing — check: systemctl status non-nixos-gpu"
fi
