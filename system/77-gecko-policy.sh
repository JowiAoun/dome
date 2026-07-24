#!/usr/bin/env bash
# 77-gecko-policy.sh — Firefox and Thunderbird settings, as enterprise policy.
#
# The Gecko half of what 79-brave-policy.sh does for the Chromium half. Same
# reasoning, different engine: settings belong in a file the application reads
# fresh at every launch, NOT in the profile's prefs.js, which is the browser's
# own live state and gets rewritten on exit.
#
# What it sets today is one preference: middle-click autoscroll — hold the
# scroll wheel down and move the mouse to pan, the way Windows does. Gecko
# ships it and defaults it OFF on Linux (ON on Windows), because middle click
# here pastes the primary selection instead. Chromium apps get the equivalent
# from modules.apps.chromiumFlags; this is the same behaviour for the two Gecko
# apps on the machine, so middle click means the same thing everywhere.
#
# WHY /etc AND NOT user.js — and why this was verified rather than assumed.
# Gecko looks for policies.json in a system directory ONLY when it was built
# with MOZ_SYSTEM_POLICIES, and the lookup lives in JavaScript inside omni.ja,
# not in the binary — so `strings libxul.so` shows nothing and proves nothing.
# Read it out of the shipped builds instead:
#
#   unzip -p <install>/omni.ja modules/EnterprisePoliciesParent.sys.mjs |
#     sed -n '/_getConfigurationFile/,/^  }/p'
#       -> if (platform == "linux" && AppConstants.MOZ_SYSTEM_POLICIES) {
#            SysConfD + "policies" + "policies.json"   # = /etc/<app>/policies/
#
#   unzip -p <install>/omni.ja modules/AppConstants.sys.mjs |
#     grep -o 'MOZ_SYSTEM_POLICIES: *[a-z]*'
#       -> MOZ_SYSTEM_POLICIES: true      (both the Firefox snap and nixpkgs
#                                          Thunderbird, checked on this machine)
#
# That path is checked FIRST and returns immediately, which is the whole reason
# it works for the snap — the snap's own install tree is read-only, and its
# AppArmor profile already grants `/etc/firefox{,/,/**} rk`.
#
# ...and that "returns immediately" is also the trap. See the Thunderbird note
# below: the system file REPLACES the shipped one, it does not merge with it.
#
# Only prefs on Gecko's allowlist can be set this way (Policies.sys.mjs,
# `allowedPrefixes`) — `general.autoScroll` is on it by name. A pref that is not
# is ignored silently, so check before adding one.
#
# ON by default in the template. Turn it off with `geckoPolicy = false;` in
# user-config.nix (which REMOVES the files), or for a single run:
#   sudo bash system/run.sh --no-gecko-policy
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

# Status "default" rather than "locked": this sets what the preference starts
# out as, and leaves the user free to change it in the UI afterwards. "locked"
# would grey the control out, which is right for the security settings in
# 79-brave-policy.sh and wrong for a mouse-behaviour preference.
read -r -d '' AUTOSCROLL_PREF <<'EOF' || true
      "general.autoScroll": { "Status": "default", "Value": true }
EOF

read -r -d '' FIREFOX_POLICY <<EOF || true
{
  "policies": {
    "Preferences": {
$AUTOSCROLL_PREF
    }
  }
}
EOF

# Thunderbird carries DisableAppUpdate as well, and that is NOT an extra
# opinion — it is damage control. nixpkgs' Thunderbird ships its own
# policies.json in the install tree:
#
#   $ cat ~/.nix-profile/lib/thunderbird/distribution/policies.json
#   {"policies":{"DisableAppUpdate":true}}
#
# and because Gecko RETURNS the system file the moment it exists rather than
# merging the two, writing /etc/thunderbird/policies/policies.json shadows that
# file completely. Without this key, installing this policy would quietly switch
# Thunderbird's self-updater back on for a copy that lives in a read-only Nix
# store, where an update cannot succeed. The drift check below is what stops
# that going unnoticed if nixpkgs ever adds a second key there.
read -r -d '' THUNDERBIRD_POLICY <<EOF || true
{
  "policies": {
    "DisableAppUpdate": true,
    "Preferences": {
$AUTOSCROLL_PREF
    }
  }
}
EOF

# user-config.nix is the source of truth; GECKO_POLICY=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag geckoPolicy; then want=1; fi
case "${GECKO_POLICY:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

apps="firefox thunderbird"

# ── off: remove what we wrote, leave everything else alone ───────────────────
if [ "$want" != 1 ]; then
  removed=0
  for app in $apps; do
    f="/etc/$app/policies/policies.json"
    [ -f "$f" ] || continue
    log "geckoPolicy is off — removing $f"
    if [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would remove $f"
    else
      rm -f "$f"
      # Only our own directories, and only while empty: rmdir refuses a
      # non-empty one, so another admin's files keep their home.
      rmdir "/etc/$app/policies" 2>/dev/null || true
      rmdir "/etc/$app" 2>/dev/null || true
    fi
    removed=1
  done
  if [ "$removed" = 1 ]; then
    mark_change
    log "  restart Firefox/Thunderbird to hand these settings back to the app"
  else
    log "Gecko managed policy not requested — nothing to remove"
  fi
  exit 0
fi

# ── drift check: are we shadowing a policy file we do not carry? ─────────────
# Gecko does not merge, so anything in a shipped distribution/policies.json that
# our file omits is silently LOST once our file exists. This turns that into a
# loud warning instead. Best-effort: it needs python3 (for real JSON parsing)
# and the invoking user's Nix profile, and simply says nothing when it cannot
# look.
check_shadowed() { # <app> <our policy json>
  local app="$1" ours="$2" u home shipped extra
  command -v python3 >/dev/null 2>&1 || return 0
  u="$(target_user)" || return 0
  [ -n "$u" ] || return 0
  home="$(getent passwd "$u" | cut -d: -f6)"
  [ -n "$home" ] || return 0

  shipped="$home/.nix-profile/lib/$app/distribution/policies.json"
  [ -f "$shipped" ] || return 0

  extra="$(python3 - "$shipped" "$ours" <<'PY' 2>/dev/null || true
import json, sys
try:
    shipped = json.load(open(sys.argv[1])).get("policies", {})
    ours = json.loads(sys.argv[2]).get("policies", {})
except Exception:
    sys.exit(0)
print(" ".join(sorted(k for k in shipped if k not in ours)))
PY
)"
  if [ -n "$extra" ]; then
    warn "$app ships policies this file would shadow and does not carry: $extra"
    warn "  ($shipped)"
    warn "  Gecko uses the /etc file INSTEAD of that one — it does not merge them."
    warn "  Add those keys to THUNDERBIRD_POLICY/FIREFOX_POLICY in system/77-gecko-policy.sh."
  fi
}

check_shadowed thunderbird "$THUNDERBIRD_POLICY"
check_shadowed firefox "$FIREFOX_POLICY"

# ── on ───────────────────────────────────────────────────────────────────────
# Deliberately NOT gated on either app being installed. The files are inert
# without them, and writing them first means the setting is in force the very
# first time the app starts, on its very first profile.
write_policy() { # <app> <body>
  local app="$1" body="$2" dir="/etc/$1/policies" f="/etc/$1/policies/policies.json"

  if [ -f "$f" ] && [ "$(cat "$f")" = "$body" ]; then
    log "$app managed policy already up to date: $f"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would write $f (middle-click autoscroll on)"
    mark_change
    return 0
  fi

  log "writing $app managed policy: $f"
  install -d -o root -g root -m 0755 "$dir"
  # 0644: read by the app as the logged-in user, so world-readable — and
  # root-owned so an unprivileged process cannot rewrite it.
  printf '%s\n' "$body" > "$f"
  chown root:root "$f"
  chmod 0644 "$f"
  mark_change
}

write_policy firefox "$FIREFOX_POLICY"
write_policy thunderbird "$THUNDERBIRD_POLICY"

log "  middle-click autoscroll is on for Firefox and Thunderbird"
log "  restart them to apply; verify at about:policies (Active tab)"
