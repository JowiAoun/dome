#!/usr/bin/env bash
# migrate/backup.sh — capture everything a wipe would destroy that dome cannot
# rebuild from git.
#
#   bash migrate/backup.sh /media/$USER/STICK
#   make backup DEST=/media/$USER/STICK
#
# Run it LAST, with browsers closed, immediately before booting the installer.
# Everything not captured here is either in the repo, on GitHub, or re-derived
# by ./install.sh.
#
# It also copies restore.sh to the destination. That is deliberate: the restore
# happens on a fresh install BEFORE the repo has been cloned (you need the SSH
# key to clone), so the restore tool cannot live only in the repo.
set -euo pipefail

DOME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[dome]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dome:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dome:fail]\033[0m %s\n' "$*" >&2; exit 1; }

DEST="${1:-}"
[ -n "$DEST" ] || die "usage: bash migrate/backup.sh <destination>   (e.g. a mounted USB stick)"
[ -d "$DEST" ] || die "'$DEST' is not a directory"
[ -w "$DEST" ] || die "'$DEST' is not writable"

# Destination first: a wrong argument should be reported before a condition the
# user can simply resolve and retry.
#
# Refuse to back up onto the disk being wiped. Same reasoning as the LUKS header
# backup in system/95-luks.sh: it could never be read back when it is needed.
base_disk() { lsblk -npo PKNAME "$1" 2>/dev/null | head -n1; }
dest_src="$(findmnt -no SOURCE --target "$DEST" 2>/dev/null || true)"
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [ -n "$dest_src" ] && [ -n "$root_src" ] &&
   [ "$(base_disk "$dest_src")" = "$(base_disk "$root_src")" ]; then
  die "$DEST is on the same physical disk as / — a backup there dies with the wipe"
fi

# Saved logins, cookies and history are live SQLite databases. Copying them
# while the browser is running yields a profile that looks fine and is corrupt.
#
# Match process NAMES (-x), not full command lines (-f): `pgrep -f brave` also
# hits any shell, editor or grep whose arguments merely mention the word, so it
# would refuse a perfectly good backup for no reason. `.brave-wrapped` is the
# nixpkgs wrapper, `brave-browser` the .deb one.
BROWSER_PROCS='brave|brave-browser|\.brave-wrapped|firefox'
if pgrep -x "$BROWSER_PROCS" >/dev/null 2>&1; then
  running="$(pgrep -x "$BROWSER_PROCS" | xargs -r ps -o comm= -p 2>/dev/null | sort -u | tr '\n' ' ')"
  die "${running}is running — close it first (its profile is a live SQLite database)"
fi

OUT="$DEST/dome-backup"
mkdir -p "$OUT"
cd "$HOME"

# Only archive what exists: a machine without Brave should not fail the backup.
present() {
  local p keep=()
  for p in "$@"; do [ -e "$HOME/$p" ] && keep+=("$p"); done
  printf '%s\n' "${keep[@]:-}"
}

archive() { # <name> <path>...
  local name="$1"; shift
  local paths=()
  mapfile -t paths < <(present "$@")
  if [ ${#paths[@]} -eq 0 ] || [ -z "${paths[0]}" ]; then
    log "skip $name — none of its paths exist here"
    return 0
  fi
  log "$name  (${#paths[@]} path(s))"
  # No --dereference: home-manager symlinks point into /nix/store, which the
  # rebuild recreates. Following them would bloat the archive enormously.
  tar czf "$OUT/$name" --warning=no-file-changed "${paths[@]}"
}

log "destination: $OUT"

archive critical.tar.gz \
  .ssh .gnupg .claude .claude.json \
  .config/gh .config/Code .config/dconf \
  Documents Desktop Pictures Videos Music Downloads

# user-config.nix is gitignored, so it is the one part of the repo that a
# `git clone` will not bring back.
if [ -f "$DOME_ROOT/user-config.nix" ]; then
  log "user-config.nix (gitignored — not recoverable from git)"
  tar czf "$OUT/user-config.tar.gz" -C "$DOME_ROOT" user-config.nix
else
  warn "no user-config.nix found at $DOME_ROOT — ./setup.sh will re-ask every question"
fi

# Decrypts Brave's saved passwords. Without it the profile restores but every
# stored login is unreadable.
archive keyrings.tar.gz .local/share/keyrings
archive brave.tar.gz    .config/BraveSoftware
archive firefox.tar.gz  snap/firefox/common/.mozilla

# ── WiFi ─────────────────────────────────────────────────────────────────────
# /etc/NetworkManager/system-connections is root-owned and holds the PSKs. It is
# the one thing you need before you can do anything else on the new install, and
# the one thing a $HOME backup misses.
NM_DIR=/etc/NetworkManager/system-connections
if [ -d "$NM_DIR" ]; then
  log "network connections (needs sudo — this is where your WiFi password lives)"
  if sudo -n true 2>/dev/null || sudo -v; then
    sudo tar czf "$OUT/network.tar.gz" -C / "${NM_DIR#/}"
    sudo chown "$(id -u):$(id -g)" "$OUT/network.tar.gz"
    chmod 600 "$OUT/network.tar.gz"
  else
    warn "could not sudo — WiFi credentials NOT captured."
    warn "You will have to type the WiFi password by hand on the new install."
  fi
fi

# ── the restore tool travels with the data ───────────────────────────────────
if [ -f "$DOME_ROOT/migrate/restore.sh" ]; then
  cp "$DOME_ROOT/migrate/restore.sh" "$OUT/"
  log "restore.sh copied to the destination (the restore runs before the repo exists)"
fi

# ── manifest + verification ──────────────────────────────────────────────────
( cd "$OUT" && sha256sum ./*.tar.gz > SHA256SUMS )

log "verifying every archive reads back"
fail=0
for f in "$OUT"/*.tar.gz; do
  if tar tzf "$f" >/dev/null 2>&1; then
    printf '    ok   %-20s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  else
    printf '    FAIL %s\n' "$(basename "$f")"; fail=1
  fi
done
[ "$fail" -eq 0 ] || die "an archive is corrupt — do NOT wipe"

sync
echo
log "backup complete: $OUT"
log "now unplug the media, plug it back in, and run:"
log "    cd $OUT && sha256sum -c SHA256SUMS"
log "that proves the bytes are really on the device and not just in page cache."
