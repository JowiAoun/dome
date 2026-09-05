#!/usr/bin/env bash
# 30-grub-params.sh — GRUB configuration, applied once via a single
# update-grub iff anything actually changed.
#
#   all hosts:  GRUB_DISABLE_OS_PROBER=false  (24.04 hides Windows by default)
#
# The Duo's i915.enable_psr=0 (OLED flicker fix) is no longer set here: it
# belongs to linux-on-zenbook-duo, whose installer 40-zenbook-duo.sh runs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if [ ! -f "$GRUB_FILE" ]; then
  warn "$GRUB_FILE not found (no GRUB on this machine?) — skipping"
  exit 0
fi

ensure_grub_kv GRUB_DISABLE_OS_PROBER false

if [ "$GRUB_CHANGED" = 1 ] && [ "$DRY_RUN" != 1 ]; then
  log "GRUB changed — running update-grub"
  update-grub
elif [ "$GRUB_CHANGED" = 1 ]; then
  log "DRY RUN: would run update-grub"
else
  log "GRUB unchanged — skipping update-grub"
fi
