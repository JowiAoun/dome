#!/usr/bin/env bash
# 95-luks.sh — disk-encryption safety net.
#
# This script CANNOT encrypt anything. LUKS has to be created when the disk is
# partitioned — Ubuntu installer → "Advanced features…" → "Use LVM and
# encryption" — and a running root filesystem cannot be retrofitted safely.
#
# What it does is close the two gaps the installer leaves behind, both of which
# are silent until the day they cost you the disk:
#
#   1. A single-keyslot volume. The installer asks for one passphrase and stops
#      there. Unlike BitLocker there is NO escrowed recovery key anywhere —
#      forget it and the data is unrecoverable, by design.
#   2. No header backup. The LUKS header lives in the first few MB of the
#      partition and holds the wrapped master key. Corrupt it and the CORRECT
#      passphrase stops working too.
#
# Runs last in the system layer so the warning is the final thing on screen.
# Read-only unless luksHeaderBackupDir is set in user-config.nix. Never fails
# the run: an unencrypted machine (WSL, Codespaces, a generic box) is a
# legitimate configuration, not an error.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

banner() { # <line>... — a warning you cannot scroll past without noticing
  # Pads with ${#line}, which counts characters, not the bytes `%-70s` would:
  # one multi-byte glyph in the text pulls the right border in by two columns.
  # Message text is kept ASCII-only so this still holds under a C locale.
  local line pad
  printf '\033[1;33m'
  printf '  ┌%s┐\n' "$(printf '─%.0s' $(seq 1 72))"
  for line in "$@"; do
    pad=$(( 70 - ${#line} ))
    [ "$pad" -lt 0 ] && pad=0
    printf '  │ %s%*s │\n' "$line" "$pad" ''
  done
  printf '  └%s┘\n' "$(printf '─%.0s' $(seq 1 72))"
  printf '\033[0m'
}

# The dm-crypt layer under / , if there is one. Walks the dependency chain
# upward, so it finds LUKS through LVM (the guided installer's layout is
# ext4 → LVM LV → dm-crypt → partition).
root_crypt_backing() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null)" || return 1
  [ -n "$src" ] || return 1
  lsblk -no TYPE --inverse "$src" 2>/dev/null | grep -qx crypt || return 1
  # The raw partition holding the LUKS header, e.g. /dev/nvme0n1p3.
  lsblk -npo FSTYPE,NAME --inverse "$src" 2>/dev/null \
    | awk '$1 == "crypto_LUKS" { print $2; exit }'
}

# Enabled keyslots. LUKS2 lists them under "Keyslots:"; LUKS1 uses
# "Key Slot N: ENABLED". Both formats are still in the wild.
luks_keyslot_count() {
  local out
  out="$(cryptsetup luksDump "$1" 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -q '^Keyslots:'; then
    printf '%s\n' "$out" | awk '
      /^Keyslots:/            { inks = 1; next }
      /^[^[:space:]]/         { inks = 0 }
      inks && /^[[:space:]]+[0-9]+:[[:space:]]*luks/ { n++ }
      END                     { print n + 0 }'
  else
    printf '%s\n' "$out" | grep -c '^Key Slot [0-9]*: ENABLED'
  fi
}

base_disk() { lsblk -npo PKNAME "$1" 2>/dev/null | head -n1; }

LUKS_DEV="$(root_crypt_backing || true)"

if [ -z "$LUKS_DEV" ]; then
  log "root filesystem is not on LUKS — nothing to check"
  banner \
    "This machine's disk is NOT encrypted." \
    "" \
    "Encryption can only be set up while partitioning. To get it you must" \
    "reinstall and choose:" \
    "" \
    "    Erase disk and install Ubuntu -> Advanced features..." \
    "        -> Use LVM and encryption" \
    "" \
    "Nothing in dome can encrypt a disk that is already running."
  exit 0
fi

if ! command -v cryptsetup >/dev/null 2>&1; then
  # Reaching here means the initramfs unlocked the disk but the userspace tool
  # is gone; without it neither check below can run.
  warn "root is on LUKS ($LUKS_DEV) but cryptsetup is not installed"
  ensure_pkg cryptsetup
  command -v cryptsetup >/dev/null 2>&1 || { warn "cryptsetup still unavailable — skipping LUKS checks"; exit 0; }
fi

log "root is encrypted — LUKS device: $LUKS_DEV"

# Did the install actually claim the whole container? The guided installer
# normally fills the volume group, but a leftover VFree means the disk you paid
# for is sitting unused inside the encrypted container — invisible to df, and
# claimable without reinstalling.
if command -v vgs >/dev/null 2>&1; then
  vg_free_kb="$(vgs --noheadings --nosuffix --units k -o vg_free 2>/dev/null | head -n1 | tr -d ' [:alpha:]' | cut -d. -f1)"
  if [ -n "${vg_free_kb:-}" ] && [ "$vg_free_kb" -gt 10485760 ]; then   # >10 GiB
    lv_path="$(findmnt -no SOURCE / 2>/dev/null)"
    warn "$(( vg_free_kb / 1048576 )) GiB is unallocated in the volume group — / is smaller than the disk"
    warn "  claim it without reinstalling:"
    warn "    sudo lvextend -l +100%FREE $lv_path"
    warn "    sudo resize2fs $lv_path"
  else
    log "volume group fully allocated"
  fi
fi

SLOTS="$(luks_keyslot_count "$LUKS_DEV" || echo 0)"
log "enabled keyslots: $SLOTS"

if [ "$SLOTS" -le 1 ]; then
  banner \
    "!!  YOUR DISK HAS EXACTLY ONE WAY IN  !!" \
    "" \
    "One passphrase unlocks $LUKS_DEV, and it exists only in your head." \
    "There is no recovery key. Unlike BitLocker, nothing is escrowed to" \
    "any account — forget it and every byte on this disk is gone." \
    "" \
    "Add a second, independent unlock now (you will be asked for the" \
    "passphrase you already have, then a new one):" \
    "" \
    "    sudo cryptsetup luksAddKey $LUKS_DEV" \
    "" \
    "Generate a long random string for it and put that in your password" \
    "manager. It becomes your recovery key."
else
  log "more than one keyslot in use — a recovery key appears to be enrolled"
fi

# ── header backup ────────────────────────────────────────────────────────────
# Destination comes from user-config.nix, NOT the environment: `sudo make
# system` drops env vars via env_reset, so an env-var-driven backup would
# silently never happen. Same reasoning as lib.sh's config_flag/config_str.
BACKUP_DIR="$(config_str luksHeaderBackupDir)"

if [ -z "$BACKUP_DIR" ]; then
  banner \
    "No LUKS header backup is configured." \
    "" \
    "The header holds your wrapped master key. If it is ever damaged, the" \
    "correct passphrase will NOT open the disk. Back it up to removable" \
    "media, then set the path in user-config.nix:" \
    "" \
    "    luksHeaderBackupDir = \"/media/$(target_user 2>/dev/null || echo you)/STICK\";" \
    "" \
    "or run ./setup.sh again, which will ask for it."
  exit 0
fi

if [ ! -d "$BACKUP_DIR" ]; then
  warn "luksHeaderBackupDir does not exist: $BACKUP_DIR (plug the media in and re-run)"
  exit 0
fi

# A header backup on the disk it protects is worthless — you cannot mount the
# filesystem holding it without the header you are trying to recover.
DEST_SRC="$(findmnt -no SOURCE --target "$BACKUP_DIR" 2>/dev/null || true)"
if [ -n "$DEST_SRC" ] && [ "$(base_disk "$DEST_SRC")" = "$(base_disk "$LUKS_DEV")" ]; then
  warn "refusing to write the header backup to $BACKUP_DIR — that is the same"
  warn "physical disk the header protects, so it could never be used to recover it"
  exit 0
fi

LUKS_UUID="$(cryptsetup luksUUID "$LUKS_DEV" 2>/dev/null || true)"
BACKUP_FILE="$BACKUP_DIR/luks-header-${LUKS_UUID:-unknown}.img"

if [ -f "$BACKUP_FILE" ]; then
  log "header backup already present: $BACKUP_FILE"
  banner \
    "A header backup already exists for this disk." \
    "" \
    "It is a SNAPSHOT of the keyslots as they were when it was taken. If" \
    "you have since changed or removed a passphrase, the old file still" \
    "opens the disk with the OLD one. Delete and re-take it after any" \
    "passphrase change:" \
    "" \
    "    sudo rm $BACKUP_FILE" \
    "    sudo bash system/95-luks.sh"
  exit 0
fi

log "backing up the LUKS header to $BACKUP_FILE"
run cryptsetup luksHeaderBackup "$LUKS_DEV" --header-backup-file "$BACKUP_FILE"

if [ "$DRY_RUN" != 1 ]; then
  # The file carries the wrapped master key. Useless without a passphrase, but
  # it is still the most sensitive thing on that stick.
  chmod 600 "$BACKUP_FILE" 2>/dev/null || true
  if cryptsetup luksDump "$BACKUP_FILE" >/dev/null 2>&1; then
    log "verified: the backup reads back as a valid LUKS header"
  else
    warn "the header backup could not be read back — check $BACKUP_FILE"
  fi
fi

banner \
  "Header backed up. Two things to remember:" \
  "" \
  "  1. Treat that file as a secret. It contains the wrapped master key" \
  "     (useless without a passphrase, but do not publish it)." \
  "  2. Re-take it after ANY passphrase change, or it will keep opening" \
  "     the disk with the old one."
