#!/usr/bin/env bash
# 82-flatpak.sh — Flatpak, the Flathub remote, and the apps named in
# user-config.nix's `flatpakApps`.
#
# WHY THE ROOT LAYER, and not a Nix package. Flatpak is not really a program,
# it is a piece of system plumbing: a setuid helper (flatpak-system-helper),
# three systemd user units (portal, session helper, OCI authenticator), two
# environment generators, and a system-wide app store under /var/lib/flatpak.
# nixpkgs' flatpak can be built but cannot wire any of that into Ubuntu's
# systemd or its login shells, so the apt package is the one that works here —
# the same reason Docker Engine lives in this layer.
#
# WHY --system RATHER THAN --user. A system install is shared, survives a
# second user account, and lands in /var/lib/flatpak/exports/share/applications
# — which is exactly where setup.sh's app detection and modules/apps.nix
# already look. So a Flatpak installed here is automatically recorded in
# appsSkip and the Nix apps module will never install a second copy of it or
# hijack its launcher. Installing to --user would work but is invisible to half
# of that machinery.
#
# THE ONE SURPRISE: A NEWLY INSTALLED FLATPAK IS MISSING FROM THE APP GRID
# UNTIL YOU LOG OUT AND BACK IN. Flatpak's exports directory reaches an app
# through XDG_DATA_DIRS, and the package extends that variable in exactly two
# places, both of which run when a SESSION STARTS and never again:
#
#   /etc/profile.d/flatpak.sh                              (login shells)
#   /usr/lib/systemd/user-environment-generators/60-flatpak (systemd --user)
#
# Both ship in the .deb (verified with `dpkg -c`), and neither can reach the
# gnome-shell that is already running. So the first `sudo make system` after
# turning this on installs everything correctly and the app grid still shows
# nothing new. That is not a failure — it is one logout. Every later install
# appears immediately, because the session already has the path by then.
#
# TRUST. flathub.flatpakrepo carries Flathub's signing key inline and is
# fetched over TLS, so this is the same trust-on-first-use as 78-brave.sh: it
# cannot prove the first fetch was honest, but every later download is verified
# against the key pinned in the local remote config. Unlike an apt repository a
# Flatpak remote grants no root at install time — apps are unpacked as data,
# not as maintainer scripts.
#
# ON by default in the template, but it does nothing beyond installing the
# tooling until `flatpakApps` names something. Turn it off with
# `flatpak = false;` in user-config.nix, or for a single run:
#   sudo bash system/run.sh --no-flatpak
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

# user-config.nix is the source of truth; FLATPAK=1/0 overrides it for a single
# run (run.sh sets it after sudo has already dropped privileges, so it survives
# sudo's env_reset).
want=0
if config_flag flatpak; then want=1; fi
case "${FLATPAK:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  # Deliberately NOT uninstalling. `apt remove flatpak` would orphan every app
  # already installed through it — gigabytes of runtimes left behind, and the
  # apps themselves gone from the grid — which is a destructive answer to what
  # is only a "stop managing this" switch. Turning it off means dome stops
  # adding remotes and apps, nothing more.
  if command -v flatpak >/dev/null 2>&1; then
    log "flatpak is off in user-config.nix — leaving the existing install alone"
    log "  to remove it yourself:  sudo apt remove --purge flatpak   (deletes installed apps)"
  else
    log "flatpak not requested — skipping (set flatpak = true; in user-config.nix)"
  fi
  exit 0
fi

# WSL has no session bus, no portals and no app grid, so a Flatpak app there has
# nowhere to appear. Skipped rather than half-installed.
if out_matches "$(cat /proc/version 2>/dev/null || true)" -i microsoft; then
  log "WSL detected — skipping flatpak (no desktop session for the apps to appear in)"
  exit 0
fi

# ── the tooling ──────────────────────────────────────────────────────────────
ensure_pkg flatpak

# The GNOME Software plugin, only when GNOME Software is actually installed.
# Without the plugin the store shows apt/snap and silently omits everything
# Flatpak — but pulling in gnome-software itself on a machine that does not have
# it would be installing a whole app store nobody asked for.
if pkg_installed gnome-software; then
  ensure_pkg gnome-software-plugin-flatpak
else
  log "gnome-software is not installed — skipping its flatpak plugin (nothing would read it)"
fi

# Everything below needs the binary. Under DRY_RUN on a machine that does not
# have it yet, ensure_pkg only printed what it would do, so say what would
# follow and stop rather than failing on a missing command.
if ! command -v flatpak >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would add the flathub remote and install: $(config_list flatpakApps | tr '\n' ' ')"
    exit 0
  fi
  warn "flatpak is still not on PATH after the install step — skipping the rest"
  exit 0
fi

# ── the flathub remote ───────────────────────────────────────────────────────
# --if-not-exists makes this idempotent on its own; the check is here so a run
# that changes nothing says so, which is the contract every script in this
# layer claims in its header.
if out_matches "$(flatpak remotes --system --columns=name 2>/dev/null || true)" -x flathub; then
  log "flathub remote already registered (system-wide)"
else
  log "adding the flathub remote"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would run flatpak remote-add --system flathub $FLATHUB_URL"
    mark_change
  elif flatpak remote-add --system --if-not-exists flathub "$FLATHUB_URL"; then
    mark_change
  else
    warn "could not add the flathub remote (network?) — no apps will be installed this run"
    exit 0
  fi
fi

# ── the apps ─────────────────────────────────────────────────────────────────
apps=()
while IFS= read -r line; do
  [ -n "$line" ] && apps+=("$line")
done < <(config_list flatpakApps)

if [ ${#apps[@]} -eq 0 ]; then
  log "flatpakApps is empty — flatpak is ready, nothing to install"
  log "  add app ids to install them:  flatpakApps = [ \"com.spotify.Client\" ];"
  log "  find one with:  flatpak search <name>"
  exit 0
fi

installed="$(flatpak list --system --app --columns=application 2>/dev/null || true)"

missing=()
for id in "${apps[@]}"; do
  # An application id is a reverse-DNS name. Validated rather than trusted
  # because it is user-supplied text going onto a command line as root, and
  # because a typo caught here beats a confusing error from flatpak.
  if ! out_matches "$id" -E '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$'; then
    warn "not a valid flatpak application id, skipping: $id"
    continue
  fi
  if out_matches "$installed" -x "$id"; then
    log "already installed: $id"
  else
    missing+=("$id")
  fi
done

if [ ${#missing[@]} -eq 0 ]; then
  log "all ${#apps[@]} listed flatpak app(s) are installed"
else
  # The first app on a fresh machine drags in a runtime (the freedesktop or
  # GNOME platform, 1-2 GiB) that every later one then shares. Check before
  # spending it, the same way 78-brave.sh does.
  avail_kb="$(df --output=avail /var | tail -n1 | tr -d ' ')"
  if [ "${avail_kb:-0}" -lt 3145728 ]; then
    warn "less than 3 GiB free on /var — not installing flatpak apps"
    warn "  free some space, then re-run 'sudo make system'"
    exit 0
  fi

  for id in "${missing[@]}"; do
    log "installing flatpak: $id"
    if [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would run flatpak install --system flathub $id"
      mark_change
      continue
    fi
    # --noninteractive answers the "which remote?" and "install these runtimes?"
    # prompts that would otherwise hang a provisioning run forever.
    if flatpak install --system --noninteractive --assumeyes flathub "$id"; then
      mark_change
      log "installed: $id"
    else
      warn "could not install $id — check the id with 'flatpak search ${id##*.}'"
    fi
  done

  log "newly installed apps appear in the app grid after the NEXT LOGIN"
  log "  (XDG_DATA_DIRS is extended when a session starts; this one already started)"
fi

# ── updates ──────────────────────────────────────────────────────────────────
# Same reasoning as Brave's apt upgrade: nothing on this machine updates
# Flatpaks on a schedule. GNOME Software would, in the background, but it is not
# installed here — so without this a Flatpak would sit at whatever version it
# was installed at, forever.
if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would run flatpak update for the system installation"
  exit 0
fi

log "checking for flatpak updates"
if flatpak update --system --noninteractive --assumeyes; then
  :
else
  warn "flatpak update did not complete (network?) — installed apps are untouched"
fi

log "flatpak ready. Useful commands:"
log "  flatpak search <name>          find an app id"
log "  flatpak list --app             what is installed"
log "  flatpak run <id>               launch one from a terminal"
log "  add ids to flatpakApps in user-config.nix to have dome install them"
