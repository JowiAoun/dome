#!/usr/bin/env bash
# 88-faillock.sh — rate-limit password guessing at the login and lock screen,
# and at sudo, polkit and the text consoles.
#
# This machine ships with NO lockout of any kind: pam_faillock is installed
# (/usr/lib/x86_64-linux-gnu/security/pam_faillock.so) and /etc/security/faillock.conf
# exists with every line commented out, but no file in /etc/pam.d references the
# module. Guessing is therefore unlimited, at whatever rate pam_unix's ~2 s
# failure delay allows — about 30 tries a minute, forever.
#
# That is worth fixing on its own, and it is what makes a short PIN defensible:
# a 4-digit PIN is 10,000 combinations, which at 30/minute is under six hours.
# With the settings below it is 8 tries per 15 minutes, or several days.
#
# TWO TALLIES, AND NOT common-auth.
#
# The usual advice is to weave faillock into /etc/pam.d/common-auth, which
# covers every service at once with one count. A lockout would then take sudo
# and the consoles with it, and the only way back into a machine that has locked
# you out of its own recovery tools is a rescue boot.
#
# Leaving sudo out is no answer either. Each sudo waits its own 2 s, so a
# program already running as you can run hundreds at once, and a 4-digit PIN
# falls in minutes, to root. So there are two counts, kept in separate files:
#   - the screen: gdm-password, the service GDM uses for the greeter AND for
#     unlocking a locked session, so one file covers both screens;
#   - admin: sudo, sudo -i, polkit's admin prompts and the text consoles.
#     Measured in a 24.04 container: of 200 wrong sudo tries started at once,
#     10 reached the password check before the lock.
# One never locks the other, and both clear themselves. A locked login screen
# is still fixed from a console:
#
#     sudo faillock --user "$USER" --reset
#
# and a locked sudo clears itself after 10 minutes.
#
# WHY THE @include IS REPLACED RATHER THAN WRAPPED.
#
# faillock has to bracket the module that checks the password: preauth before it
# to refuse an already-locked account, authfail after it to count a failure,
# authsucc after that to clear the count. Wrapping `@include common-auth` cannot
# work, because common-auth ends in
#
#     auth  requisite  pam_deny.so
#
# and `requisite` aborts the whole stack the instant authentication fails — so
# an authfail line placed after the include is unreachable and no failure is
# ever counted. (The widely-copied Debian faillock recipes have this bug; the
# stack looks right, logs nothing, and locks nobody out.) The block below is
# common-auth's own module list, in its own order, with the three faillock
# phases woven through it — and the guard in check_common_auth refuses to touch
# anything if that list ever stops being what we copied.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

BACKUP_DIR=/var/backups/dome
BEGIN='# dome:faillock begin'
END='# dome:faillock end'

# deny        failed tries before the lockout starts
# unlock_time seconds the lockout lasts, after which it clears itself — never a
#             permanent lock needing an admin, which is the failure mode that
#             turns a fat-fingered PIN into a rescue boot
# fail_interval  window the failures have to fall inside to count
#
# 8/900 is chosen against auto-submit: with system/87-login-pin.sh a mistyped
# PIN becomes a failed attempt with no Enter pressed, so the allowance has to
# absorb ordinary fumbling. It still cuts an attacker to ~768 tries a day.
FAILLOCK_ARGS='deny=8 unlock_time=900 fail_interval=900'

# The admin tally: sudo, sudo -i, polkit's admin prompts and the text consoles.
# It is a separate file (dir=), so a lockout on one side never locks the other:
# a locked login screen is still reset from a console with sudo, and a locked
# sudo still lets you log in. It clears itself after 10 minutes. Kept in /var/lib
# rather than /run, so a reboot does not hand a guessing program a fresh count.
ADMIN_TALLY=/var/lib/faillock-admin
ADMIN_ARGS="deny=10 unlock_time=600 fail_interval=900 dir=$ADMIN_TALLY"

# target  where its stack comes from  arguments
# polkit-1 ships in /usr/lib/pam.d. A copy in /etc/pam.d takes its place, and
# deleting that copy puts the shipped one back.
PAM_TARGETS=(
  "/etc/pam.d/gdm-password|/etc/pam.d/gdm-password|$FAILLOCK_ARGS"
  "/etc/pam.d/sudo|/etc/pam.d/sudo|$ADMIN_ARGS"
  "/etc/pam.d/sudo-i|/etc/pam.d/sudo-i|$ADMIN_ARGS"
  "/etc/pam.d/polkit-1|/usr/lib/pam.d/polkit-1|$ADMIN_ARGS"
  "/etc/pam.d/login|/etc/pam.d/login|$ADMIN_ARGS"
)

# common-auth as we copied it. If pam-auth-update ever rewrites that file — a
# new module, fingerprint auth, a domain join — this signature stops matching
# and we put every file back to stock rather than authenticate against a stale
# copy.
read -r -d '' EXPECTED_COMMON_AUTH <<'EOF' || true
auth [success=2 default=ignore] pam_unix.so nullok
auth [success=1 default=ignore] pam_sss.so use_first_pass
auth requisite pam_deny.so
auth required pam_permit.so
auth optional pam_cap.so
EOF

block() { # <faillock arguments>
  cat <<EOF
$BEGIN — managed by system/88-faillock.sh, regenerated on every run.
# These lines REPLACE '@include common-auth' and are a copy of it with
# pam_faillock woven through; see that script's header for why wrapping the
# include cannot work. Turn this off with loginRateLimit = false in
# user-config.nix, which restores the @include.
auth    requisite               pam_faillock.so preauth $1
auth    [success=2 default=bad] pam_unix.so nullok
auth    [success=1 default=bad] pam_sss.so use_first_pass
auth    [default=die]           pam_faillock.so authfail $1
# authsucc clears the counter after a correct password. 'optional' rather than
# the customary 'sufficient': sufficient would return success immediately and
# skip the 'auth optional pam_gnome_keyring.so' line below, which is what hands
# the password to gnome-keyring — the login keyring would stop unlocking itself.
# The control flag only decides how the result is combined; the counter is
# cleared either way.
auth    optional                pam_faillock.so authsucc $1
auth    optional                pam_cap.so
$END
EOF
}

# The file with our block taken back out — i.e. stock. Everything is rendered
# from this, so a re-run replaces a stale block instead of nesting a new one.
strip_block() {
  local line in_block=0
  while IFS= read -r line; do
    if [ "${line#"$BEGIN"}" != "$line" ]; then
      in_block=1
      printf '%s\n' '@include common-auth'
      continue
    fi
    if [ "$line" = "$END" ]; then
      in_block=0
      continue
    fi
    if [ "$in_block" = 1 ]; then
      continue
    fi
    printf '%s\n' "$line"
  done
}

insert_block() { # <faillock arguments>
  local line
  while IFS= read -r line; do
    if [ "$line" = '@include common-auth' ]; then
      block "$1"
    else
      printf '%s\n' "$line"
    fi
  done
}

check_common_auth() {
  local actual
  actual="$(grep -E '^auth' /etc/pam.d/common-auth | tr -s ' \t' ' ' | sed 's/ $//')"
  [ "$actual" = "$EXPECTED_COMMON_AUTH" ]
}

backup_once() { # <file>
  local name
  name="$(basename "$1")"
  [ "$DRY_RUN" = 1 ] && return 0
  [ -f "$1" ] || return 0
  [ -f "$BACKUP_DIR/$name.orig" ] && return 0
  install -d -o root -g root -m 0700 "$BACKUP_DIR"
  install -o root -g root -m 0600 "$1" "$BACKUP_DIR/$name.orig"
  log "kept a stock copy at $BACKUP_DIR/$name.orig"
}

# Put one file back to stock. A copy we made in place of a shipped file is
# deleted, so the shipped one is used again.
restore() { # <target> <source>
  local target="$1" source="$2"
  [ -f "$target" ] || return 0
  out_matches "$(cat "$target")" -F "$BEGIN" || return 0
  if [ "$target" != "$source" ] && [ "$(strip_block < "$target")" = "$(cat "$source" 2>/dev/null)" ]; then
    log "removing $target, so the stack in $source is used again"
    [ "$DRY_RUN" = 1 ] || rm -f "$target"
    mark_change
  else
    log "restoring the stock $target"
    install_conf "$target" "$(strip_block < "$target")" || true
  fi
}

restore_all() {
  local entry target source
  for entry in "${PAM_TARGETS[@]}"; do
    IFS='|' read -r target source _ <<< "$entry"
    restore "$target" "$source"
  done
}

# ── gate ─────────────────────────────────────────────────────────────────────
if ! config_flag loginRateLimit; then
  restore_all
  if [ "$DRY_RUN" != 1 ]; then
    faillock --reset >/dev/null 2>&1 || true
    [ -d "$ADMIN_TALLY" ] && faillock --dir "$ADMIN_TALLY" --reset >/dev/null 2>&1 || true
  fi
  log "loginRateLimit is not enabled in user-config.nix — no lockout configured"
  exit 0
fi

if [ ! -f /usr/lib/x86_64-linux-gnu/security/pam_faillock.so ]; then
  warn "pam_faillock.so is missing — refusing to write a stack that cannot load"
  exit 0
fi

# ── the guard ────────────────────────────────────────────────────────────────
if ! check_common_auth; then
  warn "/etc/pam.d/common-auth is no longer the stack this script was written against."
  warn "  Something ran pam-auth-update — a new PAM module, fingerprint login, a"
  warn "  domain join. Copying it into the login, sudo and polkit stacks now would"
  warn "  authenticate them against a stale list, so the stock files are restored."
  warn "  Re-check the block in system/88-faillock.sh against the new common-auth,"
  warn "  update EXPECTED_COMMON_AUTH, and re-run."
  restore_all
  exit 0
fi

# ── apply ────────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" != 1 ]; then
  install -d -o root -g root -m 0755 "$ADMIN_TALLY"
fi

for entry in "${PAM_TARGETS[@]}"; do
  IFS='|' read -r target source args <<< "$entry"
  # Read our own copy if there is one, else where the stack ships.
  from="$target"
  [ -f "$from" ] || from="$source"
  if [ ! -f "$from" ]; then
    log "$target: not installed here, nothing to do"
    continue
  fi
  stock="$(strip_block < "$from")"
  if ! out_matches "$stock" -Fx '@include common-auth'; then
    warn "$target has no '@include common-auth' line to replace — leaving it alone"
    continue
  fi
  desired="$(printf '%s\n' "$stock" | insert_block "$args")"
  # Cheap sanity check on the rendered result: no password module, no login.
  if ! out_matches "$desired" -F 'pam_unix.so'; then
    warn "the rendered $target has no pam_unix.so line — refusing to install it"
    continue
  fi
  if [ "$(cat "$target" 2>/dev/null)" != "$desired" ]; then
    backup_once "$target"
  fi
  install_conf "$target" "$desired" || true
done

log "login rate limit: $FAILLOCK_ARGS on the login and lock screen"
log "admin rate limit: $ADMIN_ARGS on sudo, polkit and the consoles"
log "  each clears itself, and one never locks the other:"
log "  a locked login screen:  sudo faillock --user \$USER --reset"
log "  a locked sudo:          wait 10 minutes; it clears itself"
log "  check the tallies with: faillock --user \$USER; sudo faillock --dir $ADMIN_TALLY --user \$USER"
log "  takes effect immediately — PAM re-reads the stack on every attempt"
