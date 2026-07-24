#!/usr/bin/env bash
# 79-brave-policy.sh — Brave's settings, as enterprise policy in /etc.
#
# Brave is Chromium, so it reads managed policy from
# /etc/brave/policies/managed/*.json at every launch. That path is compiled into
# the binary, not configured anywhere — confirmed against the shipped build
# rather than taken from documentation:
#
#   strings .../opt/brave.com/brave/brave | grep -E '^/etc/'
#     /etc/brave/policies          <- Brave
#     /etc/chromium/policies       <- the Chromium it is built from
#
# Why policy and not preferences. The obvious alternative is to write settings
# into the browser profile (~/.config/BraveSoftware/.../Preferences). Don't: that
# file is the browser's own live state, rewritten on exit, so an edit is either
# clobbered or fights the running browser. Policy is read fresh from /etc on
# every start, applies to every profile, and shows in the UI as "managed by your
# organisation" with the control greyed out, so it cannot drift back.
#
# Why this survives updates — the point of doing it this way:
#   - Nothing here names a Brave version, a Chromium version or an install path,
#     so an upgrade cannot invalidate it. /etc is not touched by the .deb.
#   - Chromium IGNORES policy keys it does not recognise. If a future Brave
#     retires one of these, that line becomes a silent no-op instead of an
#     error, and the rest keep applying.
#   - Both installs honour it: /etc/brave/policies is compiled in, so this file
#     governs Brave from Brave's apt repo AND the nixpkgs build, which matters
#     while braveBrowser is being adopted.
#
# Every key below was read out of the shipped binary, not from a support page:
#
#   strings .../opt/brave.com/brave/brave | grep -xE 'Brave[A-Za-z]+(Disabled|Enabled)'
#
# which is also how to check a key you want to add before adding it. Note the
# polarity is not consistent upstream — some are *Disabled (set true to turn the
# feature off), some are *Enabled (set false) — so it is worth grepping for the
# exact spelling rather than assuming.
#
# ON by default in the template. Turn it off with `braveManagedPolicy = false;`
# in user-config.nix (which REMOVES the file, handing the settings back to the
# browser UI), or for a single run:  sudo bash system/run.sh --no-brave-policy
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

POLICY_DIR="/etc/brave/policies/managed"
POLICY_FILE="$POLICY_DIR/dome.json"

# Chromium merges every *.json in the directory, so this file is named for the
# thing that owns it. Writing to a generic policies.json would silently take
# over a file that an admin, or a future Brave package, might also want.
#
# No "_comment" key marking it as dome's: brave://policy lists every key it
# reads and flags the ones it does not recognise, so a comment key would show up
# there as a broken policy. The filename carries that information instead.
read -r -d '' POLICY_BODY <<'EOF' || true
{
  "BraveAIChatEnabled": false,
  "BraveWalletDisabled": true,
  "BraveRewardsDisabled": true,
  "BraveVPNDisabled": true,
  "BraveNewsDisabled": true,
  "BraveTalkDisabled": true,
  "BraveWebDiscoveryEnabled": false,
  "HighEfficiencyModeEnabled": true
}
EOF

# What each one does, in the order above:
#
#   BraveAIChatEnabled: false     Leo, the built-in AI assistant. Removes the
#                                 sidebar entry, the omnibox suggestions and the
#                                 "Ask Leo" context-menu item.
#   BraveWalletDisabled: true     The crypto wallet: toolbar icon, brave://wallet
#                                 and the window.ethereum provider it injects
#                                 into every page.
#   BraveRewardsDisabled: true    Rewards/BAT — the triangle in the toolbar and
#                                 its onboarding prompts.
#   BraveVPNDisabled: true        The paid VPN upsell in the toolbar and settings.
#   BraveNewsDisabled: true       The news feed under the new-tab page.
#   BraveTalkDisabled: true       Brave Talk (talk.brave.com): the sidebar entry,
#                                 the new-tab widget and the "start a call"
#                                 integration. Wired to brave.talk.disabled_by_policy.
#   BraveWebDiscoveryEnabled: false
#                                 Web Discovery, the opt-in scheme that sends
#                                 search/browsing data to build Brave's index.
#                                 Off by default already; pinned so it cannot be
#                                 switched on by a prompt.
#   HighEfficiencyModeEnabled: true
#                                 Memory Saver (brave://settings/performance):
#                                 discards inactive background tabs to reclaim
#                                 RAM and reloads them on return. This is one of
#                                 Brave's own policy keys (it ships in the
#                                 BraveSoftware.Policies.Brave ADMX template), so
#                                 brave://policy recognises it. The savings level
#                                 is left at Brave's default (it would be tuned
#                                 with MemorySaverModeSavings, which only applies
#                                 once this is on).
#
# Adding another is one line in POLICY_BODY above, after checking the spelling
# with the strings command in the header.

# user-config.nix is the source of truth; BRAVE_POLICY=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag braveManagedPolicy; then want=1; fi
case "${BRAVE_POLICY:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

# ── off: remove what we wrote, leave everything else alone ───────────────────
if [ "$want" != 1 ]; then
  if [ -f "$POLICY_FILE" ]; then
    log "braveManagedPolicy is off — removing $POLICY_FILE"
    if [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would remove $POLICY_FILE"
    else
      rm -f "$POLICY_FILE"
      # Only OUR directories, and only while they are empty: rmdir refuses a
      # non-empty one, so another admin's policy file keeps its home.
      rmdir "$POLICY_DIR" 2>/dev/null || true
      rmdir /etc/brave/policies 2>/dev/null || true
      rmdir /etc/brave 2>/dev/null || true
    fi
    mark_change
    log "  restart Brave to hand these settings back to the browser UI"
  else
    log "Brave managed policy not requested — nothing to remove"
  fi
  exit 0
fi

# ── on ───────────────────────────────────────────────────────────────────────
# Deliberately NOT gated on Brave being installed. The file is inert without it,
# and writing it first means the policy is in force the very first time Brave
# starts — so Leo and the wallet are never enabled, not even briefly.
if ! pkg_installed brave-browser && ! command -v brave-browser >/dev/null 2>&1; then
  log "Brave is not installed (yet) — writing the policy anyway, it applies on first launch"
fi

if [ -f "$POLICY_FILE" ] && [ "$(cat "$POLICY_FILE")" = "$POLICY_BODY" ]; then
  log "Brave managed policy already up to date: $POLICY_FILE"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would write $POLICY_FILE (Leo, Wallet, Rewards, VPN, News, Talk, Web Discovery off; Memory Saver on)"
  mark_change
  exit 0
fi

log "writing Brave managed policy: $POLICY_FILE"
install -d -o root -g root -m 0755 "$POLICY_DIR"
# 0644: Brave reads this as the logged-in user, so it must be world-readable —
# and root-owned so an unprivileged process cannot rewrite the browser's policy.
printf '%s\n' "$POLICY_BODY" > "$POLICY_FILE"
chown root:root "$POLICY_FILE"
chmod 0644 "$POLICY_FILE"
mark_change
log "  Leo, Wallet, Rewards, VPN, News, Talk and Web Discovery are off"
log "  restart Brave to apply; verify at brave://policy"
