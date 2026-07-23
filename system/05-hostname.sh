#!/usr/bin/env bash
# 05-hostname.sh — set the machine's name from `hostName` in user-config.nix.
#
# "Renaming the computer" means three things, and doing only the first is the
# usual way to end up half-renamed:
#
#   static   /etc/hostname — what `hostname` reports and what mDNS publishes
#            as <name>.local
#   pretty   PRETTY_HOSTNAME in /etc/machine-info — the free-form name GNOME
#            Settings > About shows as "Device Name", and what BlueZ advertises
#            as the Bluetooth device name
#   hosts    the 127.0.1.1 line in /etc/hosts — Debian/Ubuntu resolve the local
#            hostname through it, and if it still names the old host every
#            sudo call prints "unable to resolve host <old>" and stalls on a
#            DNS timeout first
#
# Leave hostName empty (the default) and this does nothing at all.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

NAME="$(config_str hostName)"
if [ -z "$NAME" ]; then
  log "hostName is not set in user-config.nix — leaving the machine name alone"
  exit 0
fi

# A single DNS label: alphanumeric ends, hyphens inside, 63 characters max.
# Rejecting here beats letting systemd silently mangle the name into something
# that no longer matches what /etc/hosts says.
if ! printf '%s' "$NAME" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'; then
  warn "hostName '$NAME' is not a valid hostname (letters, digits and inner hyphens, 63 max) — skipping"
  exit 0
fi

OLD="$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
OLD_PRETTY="$(hostnamectl --pretty 2>/dev/null || true)"

# Is the name already a field on the 127.0.1.1 line? Field-wise via awk, not a
# regex: matching the name inside the line as text says nothing about whether
# it is its own entry, and a regex anchored to a following space fails on the
# common case where the name is last on the line.
hosts_ok=0
if awk -v n="$NAME" '
      $1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == n) found = 1 }
      END { exit !found }
    ' /etc/hosts 2>/dev/null; then
  hosts_ok=1
fi

if [ "$OLD" = "$NAME" ] && [ "$OLD_PRETTY" = "$NAME" ] && [ "$hosts_ok" = 1 ]; then
  log "machine name already '$NAME' (static, pretty and /etc/hosts)"
  exit 0
fi

log "renaming this machine: '${OLD:-unknown}' -> '$NAME'"

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would set the static and pretty hostname and update /etc/hosts"
  mark_change
  exit 0
fi

# --static and --pretty separately, rather than the bare form: the bare form
# derives one from the other and mangles anything it considers not DNS-safe.
hostnamectl set-hostname --static "$NAME" || { warn "could not set the static hostname"; exit 0; }
hostnamectl set-hostname --pretty "$NAME" || warn "could not set the pretty hostname (Settings > About may still show the old name)"
mark_change

# /etc/hosts: swap the old name for the new one on the 127.0.1.1 line, keeping
# any other aliases on it, and add the line if it is missing entirely.
cp -n /etc/hosts /etc/hosts.dome.bak 2>/dev/null || true
tmp="$(mktemp)"
# shellcheck disable=SC2064  # expand tmp now so the trap knows the path
trap "rm -f '$tmp'" EXIT

if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  awk -v old="$OLD" -v new="$NAME" '
    $1 == "127.0.1.1" {
      out = $1; found = 0
      for (i = 2; i <= NF; i++) {
        v = ($i == old ? new : $i)
        if (v == new) found = 1
        out = out "\t" v
      }
      if (!found) out = out "\t" new
      print out
      next
    }
    { print }
  ' /etc/hosts > "$tmp"
else
  cp /etc/hosts "$tmp"
  printf '127.0.1.1\t%s\n' "$NAME" >> "$tmp"
fi

# Never install a hosts file that lost localhost — that breaks far more than a
# wrong hostname does.
if ! grep -qE '^127\.0\.0\.1[[:space:]]+localhost' "$tmp"; then
  warn "generated /etc/hosts is missing the localhost entry — not writing it"
  warn "  add this line by hand:  127.0.1.1  $NAME"
  exit 0
fi

if cmp -s "$tmp" /etc/hosts; then
  log "/etc/hosts already correct"
else
  install -o root -g root -m 0644 "$tmp" /etc/hosts
  log "/etc/hosts updated (previous copy kept at /etc/hosts.dome.bak)"
  mark_change
fi

log "machine name is now '$NAME'"
log "log out and back in: the running desktop session baked the old name into"
log "SESSION_MANAGER, so X11 apps will print '_IceTransSocketUNIXConnect: Cannot"
log "connect to non-local host ${OLD}' until it is restarted"
