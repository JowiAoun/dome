#!/usr/bin/env bash
# system/run.sh — orchestrates the dome system layer.
#
# Usage:  sudo bash system/run.sh [--host generic|zenbook-duo]
#         sudo bash system/run.sh --dry-run         # preview only, changes nothing
#         sudo bash system/run.sh --snapshot        # take a Timeshift snapshot first
#
# Use the FLAGS, not `DRY_RUN=1 sudo ...`: sudo's default `env_reset` strips
# environment variables set in front of it, so the variable never reaches this
# script and a "preview" would really modify the system. (`sudo DRY_RUN=1 bash
# ...` and `sudo make system DRY_RUN=1` do work — the flags just remove the trap.)
#
# Order: preflight (read-only) → Timeshift snapshot → base → kernel → GRUB,
# then the duo-only scripts (40, 45, 50, 55) when the host profile is
# zenbook-duo, then the host-independent extras (60 docker, 70 docker-desktop,
# 80 nix-gpu).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

usage_text() { echo "usage: run.sh [--host <profile>] [--dry-run] [--snapshot] [--docker-desktop]"; }
usage() { die "$(usage_text)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] || die "--host needs a profile name (generic | zenbook-duo)"
      HOST="$2"; export HOST; shift 2
      ;;
    --dry-run)  DRY_RUN=1; export DRY_RUN; shift ;;
    --snapshot) SNAPSHOT=1; export SNAPSHOT; shift ;;
    --docker-desktop) DOCKER_DESKTOP=1; export DOCKER_DESKTOP; shift ;;
    -h|--help)  usage ;;
    *) die "unknown argument: $1 ($(usage_text))" ;;
  esac
done

# Child scripts read these from the environment; export whatever we inherited too.
export DRY_RUN SNAPSHOT="${SNAPSHOT:-0}"

require_root
PROFILE="$(host_profile)"
export HOST="$PROFILE"
log "host profile: $PROFILE   dry run: $DRY_RUN"

log "── 00-preflight.sh"
bash ./00-preflight.sh

# Numbered 90 to sort last in listings, but safety demands the snapshot
# happens before anything changes.
log "── 90-timeshift.sh (pre-change snapshot)"
bash ./90-timeshift.sh

for script in 10-apt-base.sh 20-kernel.sh 30-grub-params.sh; do
  log "── $script"
  bash "./$script"
done

if [ "$PROFILE" = zenbook-duo ]; then
  for script in 40-duo-deps.sh 45-duo-udev.sh 50-duo-sudoers.sh 55-touchpad-quirks.sh; do
    log "── $script"
    bash "./$script"
  done
else
  log "skipping duo-only scripts (40, 45, 50, 55) for profile '$PROFILE'"
fi

# Host-independent, config-gated extras. Both no-op loudly when their
# user-config.nix switch is off, so they are safe to run unconditionally.
for script in 60-docker.sh 70-docker-desktop.sh 80-nix-gpu.sh; do
  log "── $script"
  bash "./$script"
done

log "system layer complete. If GRUB or the kernel changed, reboot to apply."
