#!/usr/bin/env bash
# 90-timeshift.sh — take a Timeshift snapshot before the system layer
# changes anything. Numbered 90 to sort last in listings; run.sh invokes
# it FIRST (right after preflight).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would take a Timeshift snapshot"
  exit 0
fi

if ! command -v timeshift >/dev/null 2>&1; then
  warn "timeshift not installed yet (first run on a fresh machine?) — no snapshot this time; 10-apt-base installs it for future runs"
  exit 0
fi

# Pin the snapshot destination to the ROOT filesystem's own device. Without
# this, Timeshift's first-run mode auto-picks a destination and on the Duo it
# chose the 2 GiB /boot partition and filled it (see docs/INSTALL-LOG.md).
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
case "$ROOT_SRC" in
  /dev/*) ;;
  *)
    warn "cannot determine the root block device (findmnt: '$ROOT_SRC') — skipping snapshot"
    exit 0
    ;;
esac

log "creating Timeshift snapshot on $ROOT_SRC"
if ! timeshift --create --comments "pre-dome-system $(date +%F_%H%M)" --tags D \
     --snapshot-device "$ROOT_SRC" --scripted; then
  warn "Timeshift snapshot failed — investigate before making risky changes (continuing)"
fi
