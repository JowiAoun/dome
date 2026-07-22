#!/usr/bin/env bash
# 10-apt-base.sh — base packages every dome machine gets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

apt_update

ensure_pkg \
  build-essential \
  ca-certificates \
  curl \
  git \
  make \
  unzip \
  timeshift

# zsh as the login shell is a NICE-TO-HAVE, so it is best-effort: a network
# blip fetching a new package must never abort the provision (that would also
# stop the home-manager run that regenerates ~/.profile). zsh from apt lands in
# /etc/shells, making it a valid chsh target — unlike a /nix/store zsh, which
# breaks Wayland GDM when exported as SHELL.
if [ "${DRY_RUN:-0}" != 1 ]; then
  if ! dpkg -s zsh >/dev/null 2>&1; then
    log "installing zsh (best-effort)"
    if zsh_out="$(env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh 2>&1)"; then
      log "zsh installed"
    else
      warn "zsh install failed — login shell left unchanged; fix apt then re-run 'sudo make system'."
      printf '%s\n' "$zsh_out" | grep -m2 -E '^(E:|Err:)' | sed 's/^/    /' >&2 || true
    fi
  else
    log "zsh already installed"
  fi

  ZSH_BIN="$(command -v zsh || true)"
  DUO_USER="$(target_user 2>/dev/null || true)"
  if [ -n "$ZSH_BIN" ] && [ -n "$DUO_USER" ]; then
    current_shell="$(getent passwd "$DUO_USER" | cut -d: -f7)"
    if [ "$current_shell" != "$ZSH_BIN" ]; then
      log "setting login shell for $DUO_USER to $ZSH_BIN"
      chsh -s "$ZSH_BIN" "$DUO_USER" || warn "chsh failed — set it manually: chsh -s \"$ZSH_BIN\""
    else
      log "login shell for $DUO_USER already $ZSH_BIN"
    fi
  fi
fi
