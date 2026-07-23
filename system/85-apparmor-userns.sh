#!/usr/bin/env bash
# 85-apparmor-userns.sh — let Nix-installed Chromium/Electron apps start on
# Ubuntu 24.04.
#
# The failure it fixes (Brave, verbatim):
#   FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:166] The SUID
#   sandbox helper binary was found, but is not configured correctly. Rather
#   than run without sandboxing I'm aborting now. You need to make sure that
#   /nix/store/...-brave/opt/brave.com/brave/chrome-sandbox is owned by root
#   and has mode 4755.
#
# The chain:
#   1. Ubuntu 24.04 ships kernel.apparmor_restrict_unprivileged_userns=1, which
#      blocks unprivileged user namespaces for processes whose AppArmor profile
#      does not carry the `userns` permission (i.e. everything "unconfined").
#   2. Chromium therefore cannot use its namespace sandbox and falls back to
#      the setuid-root sandbox helper.
#   3. That helper has to be mode 4755 root-owned, and the Nix store is
#      read-only and carries no setuid bits — so it can never be.
#   4. Chromium refuses to run unsandboxed and aborts. Correct of it.
#
# Ubuntu's own answer is a per-application AppArmor profile that is unconfined
# apart from granting `userns` — see /etc/apparmor.d/{brave,code,Discord},
# which cover the .deb paths only. This installs the same thing for the store,
# so the namespace sandbox works and the sandbox stays ON. That is why this is
# not --no-sandbox: disabling Chromium's sandbox to work around a sandboxing
# restriction would trade a startup error for a genuinely less safe browser.
#
# Scope: `userns` for executables under /nix/store, nothing else — narrower
# than flipping the sysctl off, which would hand unprivileged userns back to
# every binary on the system, including anything downloaded to /tmp.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

PROFILE_PATH=/etc/apparmor.d/nix-store-userns

if ! command -v apparmor_parser >/dev/null 2>&1; then
  log "apparmor_parser not present — nothing to configure"
  exit 0
fi

# Only relevant while the restriction is on. If a future Ubuntu drops it, or
# the admin turned it off, the profile buys nothing and is not installed.
restricted="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [ "$restricted" != 1 ]; then
  log "unprivileged user namespaces are not restricted — no AppArmor profile needed"
  exit 0
fi

read -r -d '' PROFILE <<'EOF' || true
# Managed by dome (system/85-apparmor-userns.sh) — regenerated on every run.
#
# Grants unprivileged-user-namespace permission to executables in the Nix
# store, so Chromium/Electron apps installed by Nix can use their namespace
# sandbox on Ubuntu 24.04. Modelled on Ubuntu's own /etc/apparmor.d/brave.
# Unconfined apart from that one permission: this is not additional confinement
# and not a relaxation of anything outside /nix/store.
abi <abi/4.0>,
include <tunables/global>

profile nix-store-userns /nix/store/*/{bin,lib,libexec,opt,share}/** flags=(unconfined) {
  userns,

  # Site-specific additions and overrides.
  include if exists <local/nix-store-userns>
}
EOF

if [ -f "$PROFILE_PATH" ] && [ "$(cat "$PROFILE_PATH")" = "$PROFILE" ]; then
  log "AppArmor profile up to date: $PROFILE_PATH"
  # Still make sure it is loaded — /sys/kernel/security is not persistent and a
  # profile file on disk is no guarantee the kernel has it.
  if [ -r /sys/kernel/security/apparmor/profiles ] &&
     grep -q '^nix-store-userns ' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    log "profile is loaded"
    exit 0
  fi
  log "profile is on disk but not loaded — loading it"
else
  log "installing AppArmor profile: $PROFILE_PATH"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would write $PROFILE_PATH and load it"
    mark_change
    exit 0
  fi
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmp now so the trap knows the path
  trap "rm -f '$tmp'" EXIT
  printf '%s\n' "$PROFILE" > "$tmp"
  # Parse before installing: a bad profile that reaches /etc/apparmor.d can
  # make the apparmor service fail to start on the next boot.
  if ! apparmor_parser -Q -T "$tmp" >/dev/null 2>&1; then
    warn "generated AppArmor profile failed to parse — not installing it"
    apparmor_parser -Q -T "$tmp" 2>&1 | sed 's/^/    /' >&2 || true
    exit 0
  fi
  install -o root -g root -m 0644 "$tmp" "$PROFILE_PATH"
  mark_change
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would load $PROFILE_PATH"
  exit 0
fi

# Non-fatal, like the GPU setup next door: a browser that will not start is
# annoying, losing the rest of the provision over it is worse.
if apparmor_parser -r -W "$PROFILE_PATH" 2>/dev/null || apparmor_parser -r "$PROFILE_PATH"; then
  log "AppArmor profile loaded — Nix Chromium/Electron apps can sandbox properly now"
  log "already-running copies must be restarted"
else
  warn "could not load $PROFILE_PATH — Nix Chromium/Electron apps will still refuse to start"
  warn "  retry with:  sudo apparmor_parser -r $PROFILE_PATH"
fi
