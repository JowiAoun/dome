#!/usr/bin/env bash
# 75-claude-desktop.sh — the Claude desktop app (Linux beta).
#
# Not a Nix package: nixpkgs has no claude-desktop attribute (checked), and
# Anthropic publishes it through their own signed apt repository. So it is a
# root-layer install like Docker Desktop next door, and it updates with the
# rest of the system on `apt upgrade` rather than through a Nix generation.
#
# ON by default in the template, because it is the app this whole repo exists
# to support. Turn it off with `claudeDesktop = false;` in user-config.nix, or
# for a single run:  sudo bash system/run.sh --no-claude-desktop
#
# Source: https://code.claude.com/docs/en/desktop-linux
# Requires Ubuntu 22.04+ / Debian 12+ on amd64 or arm64.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
KEY_PATH="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
LIST_PATH="/etc/apt/sources.list.d/claude-desktop.list"
REPO="https://downloads.claude.ai/claude-desktop/apt/stable stable main"

# The fingerprint Anthropic documents for the signing key. Downloading a key
# over TLS only proves it came from that host; pinning the fingerprint is what
# makes a swapped key fail loudly instead of silently becoming trusted for
# every future apt upgrade.
EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# user-config.nix is the source of truth; CLAUDE_DESKTOP=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag claudeDesktop; then want=1; fi
case "${CLAUDE_DESKTOP:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  log "Claude Desktop not requested — skipping (set claudeDesktop = true; in user-config.nix)"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64 | arm64) ;;
  *)
    warn "Claude Desktop publishes amd64 and arm64 only (this machine is $ARCH) — skipping"
    exit 0
    ;;
esac

# Already installed? Nothing to do — apt upgrade keeps it current from here.
# Still make sure the repository is registered, so a copy installed by hand
# from a downloaded .deb starts receiving updates.
already=0
pkg_installed claude-desktop && already=1

if [ "$already" = 1 ] && [ -f "$KEY_PATH" ] && grep -qs "^deb .*downloads\.claude\.ai" "$LIST_PATH"; then
  log "Claude Desktop already installed and its apt repository is registered"
  exit 0
fi

avail_kb="$(df --output=avail / | tail -n1 | tr -d ' ')"
if [ "$already" != 1 ] && [ "${avail_kb:-0}" -lt 2097152 ]; then
  warn "less than 2 GiB free on / — not installing Claude Desktop"
  warn "  free some space, then re-run 'sudo make system'"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would install the signing key, register $REPO and apt-get install claude-desktop"
  mark_change
  exit 0
fi

# ── signing key ──────────────────────────────────────────────────────────────
if [ ! -f "$KEY_PATH" ]; then
  log "fetching Anthropic's package signing key"
  tmpkey="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmpkey now so the trap knows the path
  trap "rm -f '$tmpkey'" EXIT
  if ! curl -fsSL --retry 3 "$KEY_URL" -o "$tmpkey"; then
    warn "could not download the signing key (network?) — skipping Claude Desktop"
    exit 0
  fi
  [ -s "$tmpkey" ] || { warn "downloaded signing key is empty — skipping Claude Desktop"; exit 0; }

  # Verify before trusting. A mismatch is a hard stop, not a warning: installing
  # under an unexpected key would trust it for every later apt upgrade.
  if command -v gpg >/dev/null 2>&1; then
    got="$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [ -z "$got" ]; then
      warn "could not read a fingerprint from the downloaded key — skipping Claude Desktop"
      exit 0
    fi
    if [ "$got" != "$EXPECTED_FPR" ]; then
      warn "signing key fingerprint MISMATCH — refusing to install Claude Desktop"
      warn "  expected: $EXPECTED_FPR"
      warn "  got:      $got"
      warn "  nothing was changed. Verify against https://code.claude.com/docs/en/desktop-linux"
      exit 0
    fi
    log "signing key verified ($EXPECTED_FPR)"
  else
    warn "gpg is not installed — cannot verify the signing key fingerprint"
    warn "  installing anyway; verify later with: gpg --show-keys $KEY_PATH"
  fi

  install -o root -g root -m 0644 "$tmpkey" "$KEY_PATH"
  mark_change
else
  log "signing key already installed: $KEY_PATH"
fi

# ── repository ───────────────────────────────────────────────────────────────
LIST_LINE="deb [arch=amd64,arm64 signed-by=$KEY_PATH] $REPO"
if [ -f "$LIST_PATH" ] && [ "$(cat "$LIST_PATH")" = "$LIST_LINE" ]; then
  log "apt repository already registered: $LIST_PATH"
else
  log "registering Anthropic's apt repository"
  printf '%s\n' "$LIST_LINE" > "$LIST_PATH"
  chmod 0644 "$LIST_PATH"
  mark_change
  # The index for the new repository has to exist before the install below.
  FORCE_APT_UPDATE=1 apt_update
fi

# ── package ──────────────────────────────────────────────────────────────────
if [ "$already" = 1 ]; then
  log "Claude Desktop already installed — repository registered, it will update with apt"
  exit 0
fi

log "installing Claude Desktop (beta)"
if env DEBIAN_FRONTEND=noninteractive apt-get install -y claude-desktop; then
  mark_change
  log "Claude Desktop installed — launch 'Claude' from the app grid and sign in"
  log "it does not self-update: new versions arrive with 'sudo apt upgrade'"
else
  warn "apt could not install claude-desktop (see the output above)"
  warn "  the repository is registered; retry with: sudo apt update && sudo apt install claude-desktop"
  exit 0
fi
