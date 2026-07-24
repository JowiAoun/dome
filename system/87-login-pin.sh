#!/usr/bin/env bash
# 87-login-pin.sh — log in when the PIN is fully typed, without pressing Enter.
#
# Installs the pin-unlock gnome-shell extension and tells the GDM greeter to
# load it. The extension submits the password once it reaches loginPinLength
# characters, which is what a Windows Hello PIN actually does — Hello stores a
# fixed-length credential and submits at that length; it does NOT test the PIN
# after every keystroke. Neither does this, and the extension's own header
# quotes the three places in gnome-shell's authPrompt.js that make per-character
# checking impossible rather than merely slow.
#
# Why the root layer, for something that is a desktop feature.
#
# The login screen is not your session. It is gnome-shell running as the `gdm`
# user, which cannot read anything in /home/jowi — so an extension in
# ~/.local/share/gnome-shell/extensions can never appear there, and
# home-manager alone cannot deliver this. /usr/share/gnome-shell/extensions is
# readable by both, so ONE copy installed here serves the greeter and the lock
# screen, and there is no second copy to drift.
#
# Which leaves enabling it, which is per-user and therefore happens twice:
#
#   greeter   the dconf drop-in below. /usr/share/dconf/profile/gdm points the
#             greeter at the compiled file-db /var/lib/gdm3/greeter-dconf-defaults,
#             and /usr/share/gdm/generate-config is Ubuntu's own script for
#             rebuilding it — so this drops a file in beside Ubuntu's and re-runs
#             theirs, rather than compiling the db by hand.
#   session   modules/desktop-shell.nix, which pins enabled-extensions. Adding
#             the uuid there is mandatory: that list is authoritative, so an
#             extension merely switched on in the Extensions app is switched back
#             off at the next `make home`.
#
# The greeter has no enabled-extensions key of its own (checked: the compiled db
# has none), so setting it here replaces nothing.
#
# SECURITY, stated plainly. Auto-submitting at a known length tells anyone
# holding the machine how long the password is — they can type characters until
# it submits by itself. It does not otherwise weaken anything: guessing was
# already unlimited and Enter is not a speed bump to an attacker with a script.
# system/88-faillock.sh is the answer to the guessing, and is a separate switch.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

UUID=pin-unlock@dome.local
SRC="./gnome-extensions/$UUID"
EXT_DIR="/usr/share/gnome-shell/extensions/$UUID"
GREETER_CONF=/usr/share/gdm/dconf/95-dome-login-pin
GENERATE_CONFIG=/usr/share/gdm/generate-config

# Remove both halves. Guarded on our own metadata.json so a path typo can never
# turn this into an rm -rf of somebody else's extension.
remove_installed() {
  local removed=0

  if [ -f "$EXT_DIR/metadata.json" ] && out_matches "$(cat "$EXT_DIR/metadata.json")" -F "$UUID"; then
    log "removing $EXT_DIR"
    [ "$DRY_RUN" = 1 ] || rm -rf "$EXT_DIR"
    removed=1
  fi

  if [ -f "$GREETER_CONF" ]; then
    log "removing $GREETER_CONF"
    [ "$DRY_RUN" = 1 ] || rm -f "$GREETER_CONF"
    removed=1
  fi

  if [ "$removed" = 1 ]; then
    mark_change
    regenerate_greeter_db
  fi
  return 0
}

regenerate_greeter_db() {
  if [ ! -x "$GENERATE_CONFIG" ]; then
    warn "$GENERATE_CONFIG is missing — the greeter keeps its current settings"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would run $GENERATE_CONFIG"
    return 0
  fi
  log "rebuilding the greeter dconf database"
  "$GENERATE_CONFIG"
}

# ── gate ─────────────────────────────────────────────────────────────────────
length="$(config_num loginPinLength)"

if [ "$length" -eq 0 ]; then
  log "loginPinLength is 0 or unset — the login screen keeps asking for Enter"
  remove_installed
  exit 0
fi

if [ "$length" -lt 4 ] || [ "$length" -gt 64 ]; then
  warn "loginPinLength=$length is out of range (4-64) — refusing to install"
  warn "  a length shorter than the real password would submit a prefix on every"
  warn "  keystroke run and never let you finish typing it"
  exit 0
fi

if [ ! -d /usr/share/gnome-shell ]; then
  log "gnome-shell is not installed — nothing to do"
  exit 0
fi

# The extension declares shell-version 46. A shell that is not 46 ignores it and
# reports it as outdated, which is the safe direction, but say so out loud
# rather than leaving a feature that silently does nothing.
shell_version="$(gnome-shell --version 2>/dev/null | sed -nE 's/^GNOME Shell ([0-9]+).*/\1/p')"
if [ -n "$shell_version" ] && [ "$shell_version" != 46 ]; then
  warn "gnome-shell is $shell_version but the extension declares 46 —"
  warn "  it will be listed as outdated and not load. Add \"$shell_version\" to"
  warn "  shell-version in $SRC/metadata.json after testing on that release."
fi

# ── the extension ────────────────────────────────────────────────────────────
changed=0

for f in metadata.json extension.js; do
  if [ ! -f "$SRC/$f" ]; then
    warn "$SRC/$f is missing — refusing to install a half extension"
    exit 0
  fi
  if install_conf "$EXT_DIR/$f" "$(cat "$SRC/$f")"; then changed=1; fi
done

# The length the extension reads at enable(). Kept as a plain file beside the
# code, not in GSettings: it comes from user-config.nix and is re-asserted here
# on every run, and one file readable by both the gdm user and the logged-in
# user beats writing the same key into two separate dconf databases.
if install_conf "$EXT_DIR/pin-length" "$length"; then changed=1; fi

# ── the greeter ──────────────────────────────────────────────────────────────
read -r -d '' GREETER_BODY <<EOF || true
# Managed by dome (system/87-login-pin.sh) — regenerated on every run.
# Compiled into /var/lib/gdm3/greeter-dconf-defaults by
# /usr/share/gdm/generate-config, which this script re-runs after any change.
[org/gnome/shell]
enabled-extensions=['$UUID']
EOF

if install_conf "$GREETER_CONF" "$GREETER_BODY"; then changed=1; fi

if [ "$changed" = 1 ]; then
  regenerate_greeter_db
else
  log "login PIN already installed and up to date"
fi

log "login PIN: submits automatically at $length characters"
log "  lock screen: needs the uuid in modules/desktop-shell.nix — run 'make home'"
log "  takes effect at the next login; gnome-shell only loads extensions at startup"
log "  if the length is wrong the extension disarms after 3 tries and you can"
log "  still type the password and press Enter — set loginPinLength = 0 to remove"
