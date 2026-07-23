#!/usr/bin/env bash
# 70-docker-desktop.sh — Docker Desktop for Linux (the GUI).
#
# Not a Nix package: nixpkgs has no docker-desktop attribute (checked), and
# Docker publishes it only as a versioned .deb outside any apt repository — so
# it is a root-layer install like the engine next door.
#
# OFF by default. Turn it on with `dockerDesktop = true;` in user-config.nix,
# or for a single run:  sudo bash system/run.sh --docker-desktop
#
# Worth knowing before enabling: it is a ~450 MB download / ~2 GB installed, it
# runs the engine inside its own KVM virtual machine under a separate `docker`
# CLI context (desktop-linux), and it does not replace the native engine from
# 60-docker.sh — the two coexist and you switch with `docker context use`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

DEB_URL="https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb"

# user-config.nix is the source of truth; DOCKER_DESKTOP=1/0 overrides it for a
# single run (run.sh --docker-desktop sets it, which survives sudo's env_reset
# because run.sh exports it after sudo has already dropped privileges).
want=0
if config_flag dockerDesktop; then want=1; fi
case "${DOCKER_DESKTOP:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  log "Docker Desktop not requested — skipping (set dockerDesktop = true; in user-config.nix)"
  exit 0
fi

# Already here? Leave it alone — it ships its own in-app updater, and a
# reinstall would restart the VM under a running container workload. The
# directory check catches an install that did not come through dpkg.
if pkg_installed docker-desktop || [ -d /opt/docker-desktop ]; then
  log "Docker Desktop already installed — not touching it (it self-updates)"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" != amd64 ]; then
  warn "Docker Desktop ships an amd64 .deb only (this machine is $ARCH) — skipping"
  exit 0
fi

# The .deb depends on docker-ce-cli / docker-compose-plugin / docker-buildx-plugin,
# which only resolve once Docker's apt repository exists (60-docker.sh writes it).
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  warn "Docker's apt repository is missing — enable dockerEngine first (60-docker.sh)"
  warn "skipping Docker Desktop; its dependencies would not resolve"
  exit 0
fi

# Its engine runs in a VM, so no KVM means it installs but never starts.
if [ ! -e /dev/kvm ]; then
  warn "/dev/kvm is missing — Docker Desktop needs KVM (enable virtualization in the BIOS)"
  warn "skipping Docker Desktop"
  exit 0
fi

avail_kb="$(df --output=avail / | tail -n1 | tr -d ' ')"
if [ "${avail_kb:-0}" -lt 4194304 ]; then
  warn "less than 4 GiB free on / — not downloading Docker Desktop (~450 MB, ~2 GB installed)"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would download $DEB_URL (~450 MB) and apt-get install it"
  mark_change
  exit 0
fi

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now so the trap knows the path
trap "rm -rf '$workdir'" EXIT
deb="$workdir/docker-desktop-amd64.deb"

# Unversioned "latest" URL over HTTPS from Docker's own host — the same one
# their install docs hand out. There is no published checksum to pin against,
# so trust ends at TLS; the app self-updates after this anyway.
log "downloading Docker Desktop (~450 MB — this takes a while)"
if ! curl -fL --retry 3 --progress-bar "$DEB_URL" -o "$deb"; then
  warn "download failed (network?) — skipping Docker Desktop; re-run 'sudo make system' to retry"
  exit 0
fi
[ -s "$deb" ] || { warn "downloaded file is empty — skipping Docker Desktop"; exit 0; }

log "installing Docker Desktop"
if env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"; then
  mark_change
  log "Docker Desktop installed — launch it once from the app grid to finish setup"
else
  warn "apt could not install the .deb (see the output above) — nothing else changed"
  exit 0
fi

# Docker's docs: the desktop VM needs the invoking user in the kvm group.
DD_USER="$(target_user 2>/dev/null || true)"
if [ -n "$DD_USER" ] && id "$DD_USER" >/dev/null 2>&1 && getent group kvm >/dev/null 2>&1; then
  if id -nG "$DD_USER" | tr ' ' '\n' | grep -qx kvm; then
    log "$DD_USER is already in the kvm group"
  else
    log "adding $DD_USER to the kvm group (needed by Docker Desktop's VM)"
    run usermod -aG kvm "$DD_USER"
    log "log out and back in for the new group to apply"
  fi
fi
