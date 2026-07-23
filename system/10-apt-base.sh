#!/usr/bin/env bash
# 10-apt-base.sh — base packages every dome machine gets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

apt_update

# Heal an interrupted dpkg (e.g. a previous run Ctrl-C'd mid-install).
# No-op with no output when the state is clean.
# DEBIAN_FRONTEND=noninteractive like every other dpkg/apt call here: output is
# piped into sed, so an interactive debconf prompt would be invisible (dialog
# cannot draw into a pipe) while dpkg blocks on tty stdin — the provision would
# look frozen with nothing to answer.
if [ "$DRY_RUN" != 1 ]; then
  env DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 | sed 's/^/    /' \
    || warn "dpkg --configure -a needs manual attention"
fi

ensure_pkg \
  build-essential \
  ca-certificates \
  curl \
  git \
  make \
  openssh-client \
  unzip \
  timeshift

# zsh as the login shell is a NICE-TO-HAVE, so it is best-effort: a network
# blip fetching a new package must never abort the provision (that would also
# stop the home-manager run that regenerates ~/.profile). zsh from apt lands in
# /etc/shells, making it a valid chsh target — unlike a /nix/store zsh, which
# breaks Wayland GDM when exported as SHELL.
if [ "${DRY_RUN:-0}" != 1 ]; then
  if ! pkg_installed zsh; then
    # Stream apt's output: hiding chatter is fine, hiding PROGRESS makes a
    # working download look like a hang (someone Ctrl-C'd a healthy install).
    log "installing zsh (best-effort; ~5 MB download — apt output follows)"
    if env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh; then
      log "zsh installed"
    else
      warn "zsh install failed (details above) — login shell left unchanged; fix apt then re-run 'sudo make system'."
    fi
  else
    log "zsh already installed"
  fi

  ZSH_BIN="$(command -v zsh || true)"
  DUO_USER="$(target_user 2>/dev/null || true)"
  # A configured username that doesn't exist here (hand-copied user-config.nix,
  # or one carried over from another machine) must not kill the provision: under
  # `set -euo pipefail` a failing getent in a command substitution aborts this
  # script silently, and run.sh's own set -e then skips kernels, GRUB and every
  # duo script with no diagnostic. Warn and move on instead.
  if [ -n "$ZSH_BIN" ] && [ -n "$DUO_USER" ] && ! id "$DUO_USER" >/dev/null 2>&1; then
    warn "configured user '$DUO_USER' does not exist on this machine — skipping the login-shell step (fix environment.username in user-config.nix)"
    DUO_USER=""
  fi
  if [ -n "$ZSH_BIN" ] && [ -n "$DUO_USER" ]; then
    current_shell="$(getent passwd "$DUO_USER" | cut -d: -f7 || true)"
    if [ "$current_shell" != "$ZSH_BIN" ]; then
      log "setting login shell for $DUO_USER to $ZSH_BIN"
      chsh -s "$ZSH_BIN" "$DUO_USER" || warn "chsh failed — set it manually: chsh -s \"$ZSH_BIN\""
    else
      log "login shell for $DUO_USER already $ZSH_BIN"
    fi
  fi
fi
