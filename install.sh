#!/usr/bin/env bash
# install.sh — one-command setup on a fresh Ubuntu machine.
#
#   git clone https://github.com/JowiAoun/dome ~/.dotfiles
#   cd ~/.dotfiles
#   ./install.sh --host zenbook-duo --disable cloud
#
# Flags:
#   --host <name>          host profile (generic | zenbook-duo); default generic
#   --enable <m1,m2,...>   turn language/tool modules on  (python node java ai cloud)
#   --disable <m1,m2,...>  turn language/tool modules off
#
# Order: user-config.nix → system layer (sudo) → Nix → home-manager.
# WSL/Codespaces keep using bootstrap.sh; this script is for full machines.

set -euo pipefail
cd "$(dirname "$0")"

HOST_PROFILE=""
ENABLE_MODS=""
DISABLE_MODS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_PROFILE="$2"; shift 2 ;;
    --enable) ENABLE_MODS="$2"; shift 2 ;;
    --disable) DISABLE_MODS="$2"; shift 2 ;;
    -h|--help)
      echo "usage: ./install.sh [--host generic|zenbook-duo] [--enable m1,m2] [--disable m1,m2]"
      echo "modules: python node java ai cloud"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

set_module() { # <name> <true|false>
  case "$1" in
    python|node|java|ai|cloud) ;;
    *) echo "[dome] unknown module: $1 (valid: python node java ai cloud)" >&2; exit 1 ;;
  esac
  sed -i "s|^\(\s*\)$1 = .*;|\1$1 = $2;|" user-config.nix
  echo "[dome] module $1 = $2"
}

# ── 1. user-config.nix ───────────────────────────────────────────────────────
if [ ! -f user-config.nix ]; then
  cp user-config.template.nix user-config.nix
  echo "[dome] created user-config.nix — review name/email before relying on it"
fi

# Environment facts are re-detected on every run (a hand-copied template
# carries wrong defaults, e.g. isWSL = true on a real laptop).
sed -i "s|username = \".*\";|username = \"$USER\";|" user-config.nix
sed -i "s|homeDirectory = \".*\";|homeDirectory = \"$HOME\";|" user-config.nix
if grep -qi microsoft /proc/version 2>/dev/null; then
  sed -i "s|isWSL = .*;|isWSL = true;|" user-config.nix
else
  sed -i "s|isWSL = .*;|isWSL = false;|" user-config.nix
fi
if [ -n "${CODESPACES:-}" ] || [ -n "${CODESPACE_NAME:-}" ]; then
  sed -i "s|isCodespaces = .*;|isCodespaces = true;|" user-config.nix
else
  sed -i "s|isCodespaces = .*;|isCodespaces = false;|" user-config.nix
fi

if [ -n "$HOST_PROFILE" ] && grep -q 'hostProfile' user-config.nix; then
  sed -i "s|hostProfile = \".*\";|hostProfile = \"$HOST_PROFILE\";|" user-config.nix
fi

IFS=','
for m in $ENABLE_MODS;  do [ -n "$m" ] && set_module "$m" true;  done
for m in $DISABLE_MODS; do [ -n "$m" ] && set_module "$m" false; done
unset IFS

PROFILE="${HOST_PROFILE:-$(sed -nE 's/.*hostProfile *= *"([^"]+)".*/\1/p' user-config.nix | head -n1)}"
PROFILE="${PROFILE:-generic}"
echo "[dome] host profile: $PROFILE"

# ── 2. system layer (root) ───────────────────────────────────────────────────
sudo make system HOST="$PROFILE"

# ── 3. Nix (official upstream installer, multi-user daemon) ──────────────────
if ! command -v nix >/dev/null 2>&1; then
  echo "[dome] installing Nix (official installer, --daemon)"
  sh <(curl -L https://nixos.org/nix/install) --daemon
  # shellcheck disable=SC1091
  [ -f /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh
fi

mkdir -p "$HOME/.config/nix"
if ! grep -qs 'experimental-features' "$HOME/.config/nix/nix.conf"; then
  echo 'experimental-features = nix-command flakes' >> "$HOME/.config/nix/nix.conf"
fi

# ── 4. user layer (home-manager) ─────────────────────────────────────────────
# path:. (not plain .) so the gitignored user-config.nix is included in the
# flake source — a git+file flake copies tracked files only.
nix run home-manager/master -- switch --flake "path:.#$PROFILE" -b backup

echo "[dome] done. If 'make system' changed the kernel or GRUB, reboot to apply."
echo "[dome] on the Duo, verify with: duo doctor"
