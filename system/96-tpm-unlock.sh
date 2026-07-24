#!/usr/bin/env bash
# 96-tpm-unlock.sh — TPM2 auto-unlock for the LUKS root (opt-in).
#
# Enrolls the encrypted root into the TPM so the initramfs unlocks the disk from
# the chip instead of asking for a passphrase at every boot. Gated on
# `tpmAutoUnlock = true` in user-config.nix — off by default, because it is a
# real security trade-off (see the banner at the end): the disk stays encrypted
# against a pulled drive or a powered-off theft, but anyone who can power the
# machine on reaches the login screen without the disk passphrase.
#
# Why Clevis, not systemd-cryptenroll:
#   The systemd-native path (`systemd-cryptenroll --tpm2-device=auto` +
#   `tpm2-device=auto` in crypttab) is only honored by systemd's sd-cryptsetup,
#   which is NOT present in Ubuntu's script-based initramfs-tools initramfs
#   (Launchpad #1980018, still open). On stock Noble the option is silently
#   ignored — update-initramfs even prints `ignoring unknown option
#   'tpm2-device'` — and the disk still prompts. Switching to it means replacing
#   initramfs-tools with dracut, a large change to the boot pipeline the rest of
#   this repo (95-luks.sh, the crypttab it relies on) is built around. Clevis
#   plugs into the initramfs-tools cryptroot path that Ubuntu already ships, so
#   the pipeline is unchanged. The two mechanisms are mutually exclusive; this
#   script commits to Clevis and leaves /etc/crypttab untouched (a plain
#   `... none luks` line is exactly what Clevis wants).
#
# Why PCR 7 only:
#   PCR 7 measures Secure Boot state + enrolled keys. It is unchanged by ordinary
#   signed kernel/initramfs updates, so the binding survives them — the whole
#   point of a low-maintenance setup. Adding PCR 0/2/4 (firmware, option ROMs,
#   boot path) would re-lock on every BIOS/GRUB update and force a re-enroll.
#   The passphrase keyslot is never removed, so a PCR mismatch (or any TPM
#   failure) falls through to the passphrase prompt automatically — no lockout.
#
# The Noble tss-user fix:
#   clevis-initramfs on 24.04 does not carry the `tss` user into the initramfs,
#   and clevis-decrypt-tpm2 drops privileges to it for TPM access — so without
#   the fix the unseal fails and boot falls back to the passphrase. We install a
#   tiny initramfs-tools hook that copies the host `tss` passwd/group lines into
#   the initramfs. Source: github.com/R1DEN/ubuntu-luks-tpm (tested on 24.04.3).
#
# Idempotent: re-running skips the bind if a tpm2 slot already exists and only
# rewrites the hook / rebuilds the initramfs when something actually changed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

# A warning box you cannot scroll past without noticing (same as 95-luks.sh;
# lib.sh has no banner helper and 95's copy is a file-local function).
banner() { # <line>...
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

if ! config_flag tpmAutoUnlock; then
  log "tpmAutoUnlock is off — leaving the LUKS passphrase prompt in place"
  exit 0
fi

# The raw crypto_LUKS partition under / (walk up through LVM → dm-crypt →
# partition, same as 95-luks.sh). Enroll against THIS, never the LV on top of it.
root_luks_partition() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null)" || return 1
  [ -n "$src" ] || return 1
  lsblk -no TYPE --inverse "$src" 2>/dev/null | grep -qx crypt || return 1
  # -r (raw): without it lsblk prepends tree-drawing glyphs (└─) to NAME, which
  # get glued onto the device path and passed to cryptsetup as `└─/dev/...`.
  lsblk -rnpo FSTYPE,NAME --inverse "$src" 2>/dev/null \
    | awk '$1 == "crypto_LUKS" { print $2; exit }'
}

LUKS_DEV="$(root_luks_partition || true)"
if [ -z "$LUKS_DEV" ]; then
  warn "tpmAutoUnlock is set but root is not on LUKS — nothing to enroll"
  exit 0
fi

# A TPM has to exist to hold the key.
if [ ! -e /dev/tpm0 ] && [ ! -e /dev/tpmrm0 ]; then
  warn "tpmAutoUnlock is set but no TPM device (/dev/tpm0) is present — skipping"
  exit 0
fi

# PCR 7 is only meaningful with Secure Boot on: it measures the Secure Boot
# state, and binding to it while SB is off would both weaken the guarantee and
# silently break unlock the day SB gets turned on. Refuse rather than enroll a
# binding that does not mean what it says.
if command -v mokutil >/dev/null 2>&1; then
  if ! mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
    warn "Secure Boot is not enabled — a PCR 7 binding would be weak and would"
    warn "  break the moment Secure Boot is turned on. Enable Secure Boot in"
    warn "  firmware first, then re-run. Skipping TPM enrollment."
    exit 0
  fi
else
  warn "mokutil not found — cannot confirm Secure Boot state; skipping to be safe"
  ensure_pkg mokutil
  exit 0
fi

log "root LUKS container: $LUKS_DEV — Secure Boot on, TPM present"

# ── packages ─────────────────────────────────────────────────────────────────
CLEVIS_PKGS=(clevis clevis-luks clevis-tpm2 clevis-initramfs tpm2-tools)
missing=0
for p in "${CLEVIS_PKGS[@]}"; do pkg_installed "$p" || missing=1; done
[ "$missing" = 1 ] && apt_update
ensure_pkg "${CLEVIS_PKGS[@]}"

NEED_INITRAMFS=0

# ── the Noble tss-user initramfs hook ────────────────────────────────────────
# Verbatim from github.com/R1DEN/ubuntu-luks-tpm (hooks/tss-user). Written only
# when absent or changed, so a re-run is a no-op.
HOOK=/etc/initramfs-tools/hooks/tss-user
read -r -d '' HOOK_BODY <<'EOF' || true
#!/bin/sh
PREREQ="clevis"
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
if ! grep -q "^tss:" "${DESTDIR}/etc/passwd" 2>/dev/null; then
    grep "^tss:" /etc/passwd >> "${DESTDIR}/etc/passwd"
fi
if ! grep -q "^tss:" "${DESTDIR}/etc/group" 2>/dev/null; then
    grep "^tss:" /etc/group >> "${DESTDIR}/etc/group"
fi
EOF

# Normalize both sides through $() so the trailing-newline differences between
# the heredoc capture and the file on disk don't make this look "changed" every
# run (which would break idempotency).
if [ -f "$HOOK" ] && [ -x "$HOOK" ] \
   && [ "$(cat "$HOOK" 2>/dev/null)" = "$(printf '%s' "$HOOK_BODY")" ]; then
  log "tss-user initramfs hook already in place"
else
  log "installing tss-user initramfs hook: $HOOK"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would write $HOOK and chmod +x"
  else
    printf '%s' "$HOOK_BODY" > "$HOOK"
    chmod +x "$HOOK"
  fi
  NEED_INITRAMFS=1
  mark_change
fi

# ── TPM binding ──────────────────────────────────────────────────────────────
# Adds a new keyslot bound to PCR 7; the passphrase keyslot is left intact.
if clevis luks list -d "$LUKS_DEV" 2>/dev/null | grep -q tpm2; then
  log "a TPM2 (clevis) keyslot already exists on $LUKS_DEV — not re-binding"
else
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would run: clevis luks bind -d $LUKS_DEV tpm2 '{\"pcr_ids\":\"7\",\"pcr_bank\":\"sha256\"}'"
  elif [ ! -t 0 ]; then
    # No terminal to type the existing passphrase into (clevis prompts for it to
    # authorize the new slot). Do not fail the run — print the one command to run.
    warn "no interactive terminal — run this once yourself to enroll the TPM:"
    warn "    sudo clevis luks bind -d $LUKS_DEV tpm2 '{\"pcr_ids\":\"7\",\"pcr_bank\":\"sha256\"}'"
    warn "  then re-run 'sudo make system' to rebuild and verify the initramfs"
  else
    log "binding $LUKS_DEV to the TPM (PCR 7) — enter your EXISTING LUKS passphrase when asked"
    clevis luks bind -d "$LUKS_DEV" tpm2 '{"pcr_ids":"7","pcr_bank":"sha256"}'
    NEED_INITRAMFS=1
    mark_change
  fi
fi

# ── rebuild + verify ─────────────────────────────────────────────────────────
if [ "$NEED_INITRAMFS" = 1 ]; then
  log "rebuilding initramfs for all kernels"
  run update-initramfs -u -k all
fi

if [ "$DRY_RUN" != 1 ] && clevis luks list -d "$LUKS_DEV" 2>/dev/null | grep -q tpm2; then
  img="/boot/initrd.img-$(uname -r)"
  # Structural check: ONE extraction, then look for both the tss user and the
  # tpm2 decrypt helper in the same tree. `lsinitramfs` is avoided here — on a
  # freshly-written ~90 MB image it can list incompletely and cry wolf; a real
  # extraction into our own tempdir is reliable.
  if [ -f "$img" ]; then
    tmp="$(mktemp -d)"
    ( cd "$tmp" && unmkinitramfs "$img" . >/dev/null 2>&1 ) || true
    if grep -qs "^tss:" "$tmp"/*/etc/passwd 2>/dev/null; then
      log "verified: the tss user is baked into the initramfs (Noble fix applied)"
    else
      warn "tss user not found inside the initramfs — TPM unlock may not fire yet"
    fi
    if find "$tmp" -path '*/usr/bin/clevis-decrypt-tpm2' 2>/dev/null | grep -q .; then
      log "verified: clevis-decrypt-tpm2 is present in the initramfs"
    else
      warn "clevis-decrypt-tpm2 not in the initramfs — unlock would fall back to passphrase"
    fi
    rm -rf "$tmp"
  fi

  # The decisive test: can the TPM actually release the key with the CURRENT
  # PCRs? Mirror exactly what the initramfs does at boot — read the JWE from the
  # clevis keyslot and run it through `clevis decrypt` (which drives
  # tpm2_unseal) — WITHOUT the cryptsetup open that boot does afterwards. That
  # open is skipped on purpose: the root device is already mapped as dm_crypt-0
  # here, so a second open fails with "device in use" and would mask a perfectly
  # good unseal (at boot the device is not yet open, so it succeeds). PCR 7 reads
  # the same in userspace as in the initramfs, so a pass here predicts a silent
  # boot unlock. Run in a subshell with clevis's own helper: it is written for a
  # looser shell mode, so isolate it from our set -euo pipefail, and the
  # recovered key stays inside the subshell (never logged).
  cfuncs=/usr/bin/clevis-luks-common-functions
  slot="$(clevis luks list -d "$LUKS_DEV" 2>/dev/null \
            | awk -F: '/tpm2/ { gsub(/ /,"",$1); print $1; exit }')"
  if [ -r "$cfuncs" ] && [ -n "$slot" ] && (
       set +eu
       # shellcheck source=/dev/null
       . "$cfuncs"
       jwe="$(clevis_luks_read_slot "$LUKS_DEV" "$slot" 2>/dev/null)" || exit 1
       [ -n "$jwe" ] || exit 1
       key="$(printf '%s' "$jwe" | clevis decrypt 2>/dev/null)" || exit 1
       [ -n "$key" ]
     ); then
    log "verified: the TPM unsealed the key with the current PCRs — auto-unlock will work"
  else
    warn "the TPM could not unseal the key with the current PCRs right now"
    warn "  (your passphrase still works as the fallback; inspect with:"
    warn "   clevis luks list -d $LUKS_DEV )"
  fi

  banner \
    "TPM auto-unlock is enrolled. Reboot to use it." \
    "" \
    "  * Your passphrase still works and is the automatic fallback: if the" \
    "    TPM ever refuses (see below), you just get the normal prompt." \
    "  * You may be asked for the passphrase again after a Secure Boot or" \
    "    firmware-key change (a BIOS 'dbx' update, enrolling a MOK key, or" \
    "    turning Secure Boot off). That is expected and safe. To make the TPM" \
    "    trust the new state, re-enroll:" \
    "" \
    "      sudo clevis luks unbind -d $LUKS_DEV -s <slot>   # slot from: clevis luks list -d $LUKS_DEV" \
    "      sudo clevis luks bind   -d $LUKS_DEV tpm2 '{\"pcr_ids\":\"7\",\"pcr_bank\":\"sha256\"}'" \
    "      sudo update-initramfs -u -k all" \
    "" \
    "  * To turn this off entirely: unbind as above, set tpmAutoUnlock = false" \
    "    in user-config.nix, and rebuild the initramfs."
fi
