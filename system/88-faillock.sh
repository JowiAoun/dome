#!/usr/bin/env bash
# 88-faillock.sh — rate-limit password guessing at the login and lock screen.
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
# WHY ONLY gdm-password, AND NOT common-auth.
#
# The usual advice is to weave faillock into /etc/pam.d/common-auth, which
# covers every service at once — including sudo and TTY login. That is exactly
# what makes it the wrong choice here. A lockout would then take sudo and the
# consoles with it, and the only way back into a machine that has locked you out
# of its own recovery tools is a rescue boot. Confining faillock to the screen
# that is actually exposed keeps `sudo` and Ctrl+Alt+F3 working no matter what,
# so a lockout is always fixable from the machine itself:
#
#     sudo faillock --user "$USER" --reset
#
# gdm-password is the service GDM uses for the greeter AND for unlocking a
# locked session, so one file covers both screens.
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

PAM_FILE=/etc/pam.d/gdm-password
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

# common-auth as we copied it. If pam-auth-update ever rewrites that file — a
# new module, fingerprint auth, a domain join — this signature stops matching
# and we put gdm-password back to stock rather than authenticate the login
# screen against a stale copy.
read -r -d '' EXPECTED_COMMON_AUTH <<'EOF' || true
auth [success=2 default=ignore] pam_unix.so nullok
auth [success=1 default=ignore] pam_sss.so use_first_pass
auth requisite pam_deny.so
auth required pam_permit.so
auth optional pam_cap.so
EOF

read -r -d '' BLOCK <<EOF || true
$BEGIN — managed by system/88-faillock.sh, regenerated on every run.
# These lines REPLACE '@include common-auth' and are a copy of it with
# pam_faillock woven through; see that script's header for why wrapping the
# include cannot work. Turn this off with loginRateLimit = false in
# user-config.nix, which restores the @include.
auth    requisite               pam_faillock.so preauth $FAILLOCK_ARGS
auth    [success=2 default=bad] pam_unix.so nullok
auth    [success=1 default=bad] pam_sss.so use_first_pass
auth    [default=die]           pam_faillock.so authfail $FAILLOCK_ARGS
# authsucc clears the counter after a correct password. 'optional' rather than
# the customary 'sufficient': sufficient would return success immediately and
# skip the 'auth optional pam_gnome_keyring.so' line below, which is what hands
# the password to gnome-keyring — the login keyring would stop unlocking itself.
# The control flag only decides how the result is combined; the counter is
# cleared either way.
auth    optional                pam_faillock.so authsucc $FAILLOCK_ARGS
auth    optional                pam_cap.so
$END
EOF

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

insert_block() {
  local line
  while IFS= read -r line; do
    if [ "$line" = '@include common-auth' ]; then
      printf '%s\n' "$BLOCK"
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

backup_once() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ -f "$BACKUP_DIR/gdm-password.orig" ] && return 0
  install -d -o root -g root -m 0700 "$BACKUP_DIR"
  install -o root -g root -m 0600 "$PAM_FILE" "$BACKUP_DIR/gdm-password.orig"
  log "kept a stock copy at $BACKUP_DIR/gdm-password.orig"
}

# ── gate ─────────────────────────────────────────────────────────────────────
if [ ! -f "$PAM_FILE" ]; then
  log "$PAM_FILE does not exist — GDM is not installed here, nothing to do"
  exit 0
fi

stock="$(strip_block < "$PAM_FILE")"

if ! config_flag loginRateLimit; then
  if out_matches "$(cat "$PAM_FILE")" -F "$BEGIN"; then
    log "loginRateLimit is off — restoring the stock $PAM_FILE"
    install_conf "$PAM_FILE" "$stock" || true
    [ "$DRY_RUN" = 1 ] || faillock --reset >/dev/null 2>&1 || true
  else
    log "loginRateLimit is not enabled in user-config.nix — no lockout configured"
  fi
  exit 0
fi

if [ ! -f /usr/lib/x86_64-linux-gnu/security/pam_faillock.so ]; then
  warn "pam_faillock.so is missing — refusing to write a stack that cannot load"
  exit 0
fi

if ! out_matches "$stock" -Fx '@include common-auth'; then
  warn "$PAM_FILE has no '@include common-auth' line to replace — leaving it alone"
  warn "  something else has already rewritten it; sort that out before enabling this"
  exit 0
fi

# ── the guard ────────────────────────────────────────────────────────────────
if ! check_common_auth; then
  warn "/etc/pam.d/common-auth is no longer the stack this script was written against."
  warn "  Something ran pam-auth-update — a new PAM module, fingerprint login, a"
  warn "  domain join. Copying it into $PAM_FILE now would authenticate the login"
  warn "  screen against a stale list, so the stock @include is being restored."
  warn "  Re-check the block in system/88-faillock.sh against the new common-auth,"
  warn "  update EXPECTED_COMMON_AUTH, and re-run."
  install_conf "$PAM_FILE" "$stock" || true
  exit 0
fi

# ── apply ────────────────────────────────────────────────────────────────────
desired="$(printf '%s\n' "$stock" | insert_block)"

# Cheap sanity check on the rendered result: no password module, no login.
if ! out_matches "$desired" -F 'pam_unix.so'; then
  warn "the rendered $PAM_FILE has no pam_unix.so line — refusing to install it"
  exit 0
fi

if [ "$(cat "$PAM_FILE")" != "$desired" ]; then
  backup_once
fi

install_conf "$PAM_FILE" "$desired" || true

log "login rate limit: $FAILLOCK_ARGS, on the login and lock screen only"
log "  sudo and the TTYs are deliberately NOT covered, so a lockout is always"
log "  recoverable from this machine:  sudo faillock --user \$USER --reset"
log "  check the current tally with:   faillock --user \$USER"
log "  takes effect immediately — PAM re-reads the stack on every attempt"
