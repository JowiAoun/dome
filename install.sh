#!/usr/bin/env bash
# install.sh — one-command setup on a fresh Ubuntu machine.
#
#   git clone https://github.com/JowiAoun/dome ~/.dotfiles
#   cd ~/.dotfiles
#   ./install.sh --host zenbook-duo --disable cloud
#
# Flags:
#   --host <name>          host profile (generic | zenbook-duo); default generic
#   --enable <m1,m2,...>   turn modules on  (python node java ai cloud apps)
#   --disable <m1,m2,...>  turn modules off
#   --docker-desktop       also install Docker Desktop (~450 MB, needs KVM)
#   --no-docker            skip Docker Engine in the system layer
#   --no-claude-desktop    skip the Claude desktop app (on by default)
#   --no-brave             skip Brave from Brave's apt repo (on by default);
#                          the apps module then falls back to the nixpkgs build
#
# Order: user-config.nix → system layer (sudo) → Nix → home-manager.
# WSL/Codespaces keep using bootstrap.sh; this script is for full machines.

set -euo pipefail
cd "$(dirname "$0")"

HOST_PROFILE=""
ENABLE_MODS=""
DISABLE_MODS=""
DOCKER_ENGINE=""
DOCKER_DESKTOP=""
CLAUDE_DESKTOP=""
BRAVE_BROWSER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_PROFILE="$2"; shift 2 ;;
    --enable) ENABLE_MODS="$2"; shift 2 ;;
    --disable) DISABLE_MODS="$2"; shift 2 ;;
    --docker-desktop) DOCKER_DESKTOP=true; shift ;;
    --no-docker) DOCKER_ENGINE=false; shift ;;
    --claude-desktop) CLAUDE_DESKTOP=true; shift ;;
    --no-claude-desktop) CLAUDE_DESKTOP=false; shift ;;
    --brave) BRAVE_BROWSER=true; shift ;;
    --no-brave) BRAVE_BROWSER=false; shift ;;
    -h|--help)
      echo "usage: ./install.sh [--host generic|zenbook-duo] [--enable m1,m2] [--disable m1,m2]"
      echo "                    [--docker-desktop] [--no-docker]"
      echo "modules: python node java ai cloud apps"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

set_key() { # <key> <value> — rewrite a `key = value;` line in user-config.nix
  sed -i "s|^\(\s*\)$1 = .*;|\1$1 = $2;|" user-config.nix
}

set_module() { # <name> <true|false>
  case "$1" in
    python|node|java|ai|cloud|apps) ;;
    *) echo "[dome] unknown module: $1 (valid: python node java ai cloud apps)" >&2; exit 1 ;;
  esac
  set_key "$1" "$2"
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

# System-layer switches (read by system/*.sh with sed, not by Nix). A
# user-config.nix written before they existed has no line to rewrite, and a
# missing key reads as "off" — which would silently drop Docker Engine on an
# upgraded checkout. So seed the key with its template default first, above
# hostProfile, which every config has.
ensure_system_flag() { # <key> <default>
  if grep -qE "^\s*$1 = " user-config.nix; then
    return 0
  fi
  if grep -qE '^[[:space:]]*# Host profile' user-config.nix; then
    # Above the hostProfile block, comment included, so that comment keeps
    # describing the setting underneath it.
    sed -i "s|^\([[:space:]]*\)# Host profile|\1$1 = $2;\n\n\1# Host profile|" user-config.nix
  else
    sed -i "s|^\(\s*\)hostProfile = |\1$1 = $2;\n\1hostProfile = |" user-config.nix
  fi
  echo "[dome] added missing $1 = $2 to user-config.nix"
}
ensure_system_flag dockerEngine true
ensure_system_flag dockerDesktop false
ensure_system_flag claudeDesktop true
ensure_system_flag braveBrowser true
if [ -n "$DOCKER_ENGINE" ];  then set_key dockerEngine  "$DOCKER_ENGINE";  echo "[dome] dockerEngine = $DOCKER_ENGINE";  fi
if [ -n "$DOCKER_DESKTOP" ]; then set_key dockerDesktop "$DOCKER_DESKTOP"; echo "[dome] dockerDesktop = $DOCKER_DESKTOP"; fi
if [ -n "$CLAUDE_DESKTOP" ]; then set_key claudeDesktop "$CLAUDE_DESKTOP"; echo "[dome] claudeDesktop = $CLAUDE_DESKTOP"; fi
if [ -n "$BRAVE_BROWSER" ];  then set_key braveBrowser  "$BRAVE_BROWSER";  echo "[dome] braveBrowser = $BRAVE_BROWSER";  fi

# Record which of the apps module's apps this machine already has from
# apt/snap/flatpak, so Nix never installs a second copy or hijacks its launcher.
bash setup.sh --sync-apps-skip

PROFILE="${HOST_PROFILE:-$(sed -nE 's/.*hostProfile *= *"([^"]+)".*/\1/p' user-config.nix | head -n1)}"
PROFILE="${PROFILE:-generic}"
echo "[dome] host profile: $PROFILE"

banner() { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }

# ── disk check ───────────────────────────────────────────────────────────────
# The heavy parts of a full run are downloads: Docker Engine, optionally Docker
# Desktop (~450 MB / ~2 GB installed), and the apps module's browser/Electron
# closures. Running out of space halfway leaves the switch unapplied and the
# store full of half a generation, so say so up front while it is still cheap
# to stop.
avail_gib=$(( $(df -Pk / | awk 'NR==2 {print $4}') / 1048576 ))
if [ "$avail_gib" -lt 10 ]; then
  echo
  echo "[dome] WARNING: only ${avail_gib} GiB free on / — a full install wants ~10 GiB" >&2
  echo "[dome]          (apps module ~4 GiB, Docker Engine ~1 GiB, Docker Desktop ~2 GiB)" >&2
  echo "[dome]          Free space first, or disable modules: ./install.sh --disable apps --no-docker" >&2
  if [ -t 0 ]; then
    printf '[dome] Continue anyway? (y/N): '
    read -r go
    case "${go:-}" in
      y|Y) ;;
      *) echo "[dome] stopped — nothing was changed"; exit 1 ;;
    esac
  fi
fi

# ── 2. system layer (root) ───────────────────────────────────────────────────
# Invoke the system layer directly with bash, NOT via `make`: `make` is not
# installed on a fresh Ubuntu desktop (it ships in build-essential, which the
# system layer itself installs) — going through make would fail before the
# first package is installed. `make system` stays as a convenience alias for
# later, interactive re-runs once build-essential is present.
banner "system layer (needs root — you'll be prompted for your password)"
sudo -v || { echo "[dome] sudo is required for the system layer" >&2; exit 1; }
sudo --preserve-env=DRY_RUN,SNAPSHOT bash system/run.sh --host "$PROFILE"

# ── 3. Nix (official upstream installer, multi-user daemon) ──────────────────
# Detection must NOT lean on `command -v nix` alone. `nix` is only on $PATH once
# a shell has sourced the daemon profile, and that sourcing is per-shell: a bash
# login gets it from /etc/bash.bashrc, but a zsh login on Ubuntu frequently does
# not. So source the daemon profile ourselves (a no-op if Nix is absent) and
# check the on-disk binary — otherwise merely switching login shells makes this
# step re-run the installer, which then aborts on the leftover
# *.backup-before-nix files the original, successful install left behind.
source_nix_profile() {
  local f
  for f in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    /etc/profile.d/nix.sh \
    "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    if [ -e "$f" ]; then
      set +eu  # these vendor profile scripts predate set -euo pipefail
      # shellcheck disable=SC1090
      . "$f"
      set -eu
      break
    fi
  done
}

source_nix_profile
if command -v nix >/dev/null 2>&1 || [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  echo "[dome] Nix already installed"
  source_nix_profile  # guarantee nix is on PATH for the home-manager step below
else
  banner "installing Nix (official installer, --daemon)"
  sh <(curl -L https://nixos.org/nix/install) --daemon
  source_nix_profile
fi

mkdir -p "$HOME/.config/nix"
if ! grep -qs 'experimental-features' "$HOME/.config/nix/nix.conf"; then
  echo 'experimental-features = nix-command flakes' >> "$HOME/.config/nix/nix.conf"
fi

# ── 4. user layer (home-manager) ─────────────────────────────────────────────
banner "home-manager (first run downloads a lot — be patient)"
if ! command -v nix >/dev/null 2>&1; then
  echo "[dome] 'nix' is not on PATH in this shell yet." >&2
  echo "[dome] Open a NEW terminal (so the Nix profile loads), then run:" >&2
  echo "         cd ~/.dotfiles && nix run home-manager/master -- switch --flake \"path:.#$PROFILE\" -b backup" >&2
  exit 1
fi
# path:. (not plain .) so the gitignored user-config.nix is included in the
# flake source — a git+file flake copies tracked files only.
nix run home-manager/master -- switch --flake "path:.#$PROFILE" -b backup

# ── 5. GPU for Nix GUI apps ──────────────────────────────────────────────────
# Deliberately after home-manager: the setup reads the CURRENT generation's
# activation script to find the driver bundle, so on a fresh machine there is
# nothing to read until the switch above has run. Idempotent, so `sudo make
# system` re-running it later costs nothing.
# --check needs no root, so an already-configured machine never triggers a
# second password prompt just to learn there is nothing to do.
if bash system/80-nix-gpu.sh --check >/dev/null 2>&1; then
  echo "[dome] GPU drivers for Nix apps: already set up"
else
  banner "GPU drivers for Nix apps"
  sudo bash system/80-nix-gpu.sh || echo "[dome] GPU setup skipped — re-run: sudo bash system/80-nix-gpu.sh" >&2
fi

banner "done"
echo "[dome] If the system layer changed the kernel or GRUB, reboot to apply."
echo "[dome] On the Duo, verify with: duo doctor"
