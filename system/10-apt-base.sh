#!/usr/bin/env bash
# 10-apt-base.sh — base packages every dome machine gets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: apt-get update"
else
  apt-get update
fi

ensure_pkg \
  build-essential \
  ca-certificates \
  curl \
  git \
  make \
  unzip \
  timeshift \
  zsh

# zsh installed above lands in /etc/shells, so it's a valid chsh target.
# Set it as the login user's shell (the OS way — not a /nix/store SHELL export,
# which breaks Wayland GDM). Idempotent: only chsh if not already zsh.
if [ "${DRY_RUN:-0}" != 1 ]; then
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
