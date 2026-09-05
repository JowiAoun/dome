#!/usr/bin/env bash
# 40-zenbook-duo.sh — [zenbook-duo hosts only] the root half of
# github.com/JowiAoun/linux-on-zenbook-duo: packages, kernel policy, the
# i915.enable_psr=0 GRUB param, the `duo` command, udev rules, the root helper
# + sudoers rule, the touchpad quirk and the speaker-amp reporter.
#
# Nothing Duo-specific lives in this repo any more. This script only makes
# sure the checkout exists (cloning it if not, as the target user) and runs
# its installer in --dev mode, so /usr/local/lib/zenduo is a symlink to the
# checkout and the daemons hosts/zenbook-duo points at (zenduo.repoPath) run
# the same live code. The checkout is never pulled from here: it is a working
# copy that may hold local edits, and updating it is a deliberate act.
#
# Override the location with ZENDUO_REPO=/path (must match repoPath in
# hosts/zenbook-duo/default.nix). Feature flags for that installer are
# forwarded from the environment as-is (ZENDUO_PSR_FIX=0, etc.).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if ! is_duo_host; then
  log "not a zenbook-duo host — skipping"
  exit 0
fi

DUO_USER="$(target_user)" || die "cannot determine the target user — set environment.username in user-config.nix or run via sudo from your own account"
id "$DUO_USER" >/dev/null 2>&1 || die "user '$DUO_USER' does not exist on this machine"
DUO_HOME="$(getent passwd "$DUO_USER" | cut -d: -f6)"
REPO="${ZENDUO_REPO:-$DUO_HOME/p/linux-on-zenbook-duo}"
REPO_URL="https://github.com/JowiAoun/linux-on-zenbook-duo"

if [ -f "$REPO/install.sh" ]; then
  log "linux-on-zenbook-duo checkout: $REPO ($(cat "$REPO/VERSION" 2>/dev/null || echo 'unknown version'))"
else
  log "cloning $REPO_URL to $REPO (as $DUO_USER)"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would git clone"
    log "DRY RUN: would run $REPO/install.sh --system --dev"
    exit 0
  fi
  runuser -u "$DUO_USER" -- install -d "$(dirname "$REPO")"
  runuser -u "$DUO_USER" -- git clone -q "$REPO_URL" "$REPO" || die "clone failed — no network? clone it by hand and re-run"
  mark_change
fi

# Its own installer owns idempotency and DRY_RUN; --user names the account
# the sudoers rule and the amp notifier are bound to.
args=(--dev --user "$DUO_USER")
[ "$DRY_RUN" = 1 ] && args+=(--dry-run)
bash "$REPO/system/run.sh" "${args[@]}"
