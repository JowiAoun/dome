#!/usr/bin/env bash
# 62-tailscale.sh: Tailscale from Tailscale's own apt repository.
#
# Tailscale puts this machine on your private network (your tailnet), so your
# other devices reach it by name from anywhere, with no port opened. It needs a
# root service, tailscaled, that owns a network interface. Nix can hand you the
# binaries but not a running system service on Ubuntu, so like Docker it lives
# in the root layer.
#
# Installing it joins nothing: log in once with `tailscale up`. This step also
# lets the target user run `tailscale` without sudo, and turns on Tailscale's
# own updates, since Ubuntu's automatic updates only cover Ubuntu's packages.
#
# Enabled by `tailscale = true;` in user-config.nix (the default for new
# configs). Set it to false to skip.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if ! config_flag tailscale; then
  log "tailscale is not enabled in user-config.nix, skipping Tailscale"
  exit 0
fi

# shellcheck disable=SC1091
. /etc/os-release
# Ubuntu flavours set VERSION_CODENAME to their own name. pkgs.tailscale.com
# publishes a suite per Ubuntu release, so use Ubuntu's name.
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"

# Tailscale's own paths, so this step and Tailscale's install script agree if
# both ever run on the same machine.
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list
REPO="deb [signed-by=$KEYRING] https://pkgs.tailscale.com/stable/ubuntu $CODENAME main"
repo_changed=0

if [ -s "$KEYRING" ]; then
  log "tailscale apt key already installed: $KEYRING"
elif [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would fetch Tailscale's apt key -> $KEYRING"
  mark_change
else
  log "fetching Tailscale's apt signing key"
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmp now: the trap must know the path
  trap "rm -f '$tmp'" EXIT
  if curl -fsSL --retry 3 "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.noarmor.gpg" -o "$tmp" && [ -s "$tmp" ]; then
    install -o root -g root -m 0644 "$tmp" "$KEYRING"
    repo_changed=1
    mark_change
  else
    warn "could not fetch Tailscale's apt key (network?), skipping Tailscale"
    exit 0
  fi
fi

if [ -f "$LIST" ] && [ "$(cat "$LIST")" = "$REPO" ]; then
  log "tailscale apt source already up to date: $LIST"
else
  log "writing $LIST"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would write $REPO"
  else
    printf '%s\n' "$REPO" > "$LIST"
    chmod 0644 "$LIST"
  fi
  repo_changed=1
  mark_change
fi

# 10-apt-base.sh already refreshed apt for this run, so only refresh again
# when the source list is new.
if [ "$repo_changed" = 1 ]; then
  apt_update
fi

ensure_pkg tailscale

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would start tailscaled, let the target user run tailscale, and turn on its updates"
  exit 0
fi

# The package starts tailscaled itself. This covers a machine where it was turned off.
if ! systemctl is-active --quiet tailscaled; then
  log "starting tailscaled"
  run systemctl enable --now tailscaled
fi

# tailscale set needs tailscaled to answer, which can take a moment after install.
ts_set() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    tailscale set "$@" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

TS_USER="$(target_user 2>/dev/null || true)"
if [ -z "$TS_USER" ] || ! id "$TS_USER" >/dev/null 2>&1; then
  warn "cannot find the target user, so tailscale still needs sudo"
elif ts_set --operator="$TS_USER"; then
  log "$TS_USER can run tailscale without sudo"
else
  warn "could not make $TS_USER the Tailscale operator, so tailscale still needs sudo"
fi

if ts_set --auto-update; then
  log "Tailscale updates itself"
else
  warn "could not turn on Tailscale's own updates. Try later: sudo tailscale set --auto-update"
fi

if [ -n "$(tailscale ip -4 2>/dev/null || true)" ]; then
  log "Tailscale is connected: $(tailscale ip -4 | head -n1)"
else
  log "Tailscale is installed. Log in once with: tailscale up"
fi
