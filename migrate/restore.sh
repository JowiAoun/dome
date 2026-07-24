#!/usr/bin/env bash
# migrate/restore.sh — put back what migrate/backup.sh captured.
#
#   bash restore.sh                 restore everything that applies
#   bash restore.sh --only network  just one phase
#   bash restore.sh --list          show phases and whether each can run now
#
# This script is COPIED ONTO THE BACKUP MEDIA by backup.sh and is meant to be
# run from there. On a fresh install you need the SSH key before you can clone
# the repo, so the restore tool cannot live only inside the repo.
#
# Every phase is idempotent and explains why it is skipping, so re-running after
# installing a missing app picks up what could not apply the first time.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[dome]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dome:warn]\033[0m %s\n' "$*" >&2; }
skip() { printf '\033[1;33m[dome:skip]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[dome:fail]\033[0m %s\n' "$*" >&2; exit 1; }

ONLY=""
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:?--only needs a phase name}"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

have() { [ -f "$DIR/$1" ]; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

if [ "$LIST" = 1 ]; then
  printf '%-10s %-22s %s\n' PHASE ARCHIVE STATUS
  for p in home network config keyring brave firefox; do
    case "$p" in
      home)    a=critical.tar.gz     ;;
      network) a=network.tar.gz      ;;
      config)  a=user-config.tar.gz  ;;
      keyring) a=keyrings.tar.gz     ;;
      brave)   a=brave.tar.gz        ;;
      firefox) a=firefox.tar.gz      ;;
    esac
    printf '%-10s %-22s %s\n' "$p" "$a" "$(have "$a" && echo present || echo 'not in backup')"
  done
  exit 0
fi

# ── integrity first ──────────────────────────────────────────────────────────
if [ -f "$DIR/SHA256SUMS" ]; then
  log "verifying archives against SHA256SUMS"
  ( cd "$DIR" && sha256sum -c SHA256SUMS ) || die "checksum mismatch — do not trust this backup"
else
  warn "no SHA256SUMS beside the archives — cannot verify integrity"
fi

# ── home: keys, personal dirs, app config ────────────────────────────────────
if want home && have critical.tar.gz; then
  log "home — keys, documents, app config"
  tar xzf "$DIR/critical.tar.gz" -C "$HOME"
  [ -d "$HOME/.ssh" ]   && chmod 700 "$HOME/.ssh"
  [ -d "$HOME/.gnupg" ] && chmod 700 "$HOME/.gnupg"
  # Private keys: anything without a .pub sibling in .ssh.
  for k in "$HOME"/.ssh/id_*; do
    [ -e "$k" ] || continue
    case "$k" in *.pub) continue ;; esac
    chmod 600 "$k"
  done
  log "  broken symlinks under ~ are expected — they point into /nix/store, which home-manager rebuilds"
elif want home; then
  skip "home — critical.tar.gz not present"
fi

# ── network: the WiFi you need before anything else works ────────────────────
NM_DIR=/etc/NetworkManager/system-connections
if want network && have network.tar.gz; then
  log "network — restoring saved connections (needs sudo)"
  if sudo -n true 2>/dev/null || sudo -v; then
    tmp="$(mktemp -d)"
    tar xzf "$DIR/network.tar.gz" -C "$tmp"
    sudo mkdir -p "$NM_DIR"
    # No-clobber: never overwrite a connection you configured during install.
    sudo cp -n "$tmp/$NM_DIR"/*.nmconnection "$NM_DIR/" 2>/dev/null || true
    sudo chown root:root "$NM_DIR"/*.nmconnection 2>/dev/null || true
    sudo chmod 600 "$NM_DIR"/*.nmconnection 2>/dev/null || true
    sudo nmcli connection reload 2>/dev/null || warn "could not reload NetworkManager — reboot to pick the profiles up"
    rm -rf "$tmp"
    log "  saved WiFi networks are back; existing connections were left alone"
  else
    warn "no sudo — skipped. Re-run this phase later: bash restore.sh --only network"
  fi
elif want network; then
  skip "network — network.tar.gz not present (WiFi password was not captured)"
fi

# ── config: the gitignored user-config.nix ───────────────────────────────────
if want config && have user-config.tar.gz; then
  if [ -d "$HOME/.dotfiles" ]; then
    log "config — user-config.nix into ~/.dotfiles"
    tar xzf "$DIR/user-config.tar.gz" -C "$HOME/.dotfiles"
  else
    log "config — ~/.dotfiles does not exist yet, staging to ~/user-config.nix"
    tar xzf "$DIR/user-config.tar.gz" -C "$HOME"
    log "  after cloning the repo:  mv ~/user-config.nix ~/.dotfiles/"
  fi
elif want config; then
  skip "config — user-config.tar.gz not present"
fi

# ── keyring: must land before Brave first runs ───────────────────────────────
if want keyring && have keyrings.tar.gz; then
  log "keyring — login keyring (decrypts Brave's saved passwords)"
  tar xzf "$DIR/keyrings.tar.gz" -C "$HOME"
elif want keyring; then
  skip "keyring — keyrings.tar.gz not present"
fi

# ── browsers ─────────────────────────────────────────────────────────────────
if want brave && have brave.tar.gz; then
  log "brave — profile"
  tar xzf "$DIR/brave.tar.gz" -C "$HOME"
elif want brave; then
  skip "brave — brave.tar.gz not present"
fi

if want firefox && have firefox.tar.gz; then
  if [ -d "$HOME/snap/firefox" ]; then
    log "firefox — profile"
    tar xzf "$DIR/firefox.tar.gz" -C "$HOME"
  else
    skip "firefox — ~/snap/firefox does not exist yet. Install Firefox and launch it once,"
    skip "          then: bash restore.sh --only firefox"
  fi
elif want firefox; then
  skip "firefox — firefox.tar.gz not present"
fi

echo
log "restore finished. Check it landed:"
log "    ssh -T git@github.com        # should greet you by name"
log "    nmcli connection show        # your saved networks"
