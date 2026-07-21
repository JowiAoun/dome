#!/usr/bin/env bash
# system/run.sh — orchestrates the dome system layer.
#
# Usage:  sudo bash system/run.sh [--host generic|zenbook-duo]
#         DRY_RUN=1 sudo bash system/run.sh          # preview only
#
# Order: preflight (read-only) → Timeshift snapshot → base → kernel → GRUB,
# then the duo-only scripts (40, 50) when the host profile is zenbook-duo.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; export HOST; shift 2 ;;
    *) die "unknown argument: $1 (usage: run.sh [--host <profile>])" ;;
  esac
done

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
  for script in 40-duo-deps.sh 45-duo-udev.sh 50-duo-sudoers.sh; do
    log "── $script"
    bash "./$script"
  done
else
  log "skipping duo-only scripts (40, 45, 50) for profile '$PROFILE'"
fi

log "system layer complete. If GRUB or the kernel changed, reboot to apply."
