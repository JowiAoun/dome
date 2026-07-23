#!/usr/bin/env bash
# 90-timeshift.sh — OPT-IN pre-change Timeshift snapshot (set SNAPSHOT=1).
#
# Default is OFF. A Timeshift rsync snapshot copies the whole root filesystem;
# on the interim ~50 GB Duo install that lands on the same small disk, is slow,
# briefly needs to duplicate the rootfs, and doesn't survive a disk failure —
# and it was blocking the (idempotent) install by sitting at "0.00% complete".
# The real rollback nets here are the GA fallback kernel, git history, and
# home-manager generations. Enable on roomy machines / before a risky change:
#   sudo bash system/run.sh --host <profile> --snapshot
# (Not `SNAPSHOT=1 sudo ...`: sudo's default env_reset drops the variable before
# this script sees it, so the snapshot would silently never happen.)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if [ "${SNAPSHOT:-0}" != 1 ]; then
  log "skipping Timeshift snapshot (opt-in: set SNAPSHOT=1 to enable)"
  exit 0
fi

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
