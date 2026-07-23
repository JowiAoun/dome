#!/usr/bin/env bash
# 60-docker.sh — Docker Engine (CE) from Docker's official apt repository.
#
# Why the root layer and not a Nix package: `docker` is a client for a
# root-owned daemon. nixpkgs can hand you the binary, but not a running
# dockerd, a /var/run/docker.sock, a systemd unit, or the `docker` group — so a
# Nix-installed client on Ubuntu only ever prints "Cannot connect to the Docker
# daemon". The user layer keeps docker-compose (a standalone binary that talks
# to whatever daemon it can reach); the engine, the CLI and the
# compose/buildx plugins come from here.
#
# Enabled by `dockerEngine = true;` in user-config.nix (the default for new
# configs). Set it to false to skip.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if ! config_flag dockerEngine; then
  log "dockerEngine is not enabled in user-config.nix — skipping Docker Engine"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"
# shellcheck disable=SC1091
. /etc/os-release
# Ubuntu flavours (Kubuntu, Pop!_OS, …) set VERSION_CODENAME to their own name;
# UBUNTU_CODENAME is the one download.docker.com actually publishes suites for.
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"

# Distro packages that claim the same paths. Docker's own install docs tell you
# to remove these first. Removing packages is destructive and out of scope for
# a provisioning script, so report and stand down instead of guessing.
conflicts=()
for p in docker.io docker-doc docker-compose-v2 podman-docker containerd runc; do
  if pkg_installed "$p"; then
    conflicts+=("$p")
  fi
done
if [ ${#conflicts[@]} -gt 0 ]; then
  warn "these distro packages conflict with Docker CE: ${conflicts[*]}"
  warn "remove them, then re-run:  sudo apt-get remove ${conflicts[*]}"
  warn "leaving Docker Engine uninstalled (nothing was changed)"
  exit 0
fi

# ── apt repository ───────────────────────────────────────────────────────────
KEYRING=/etc/apt/keyrings/docker.asc
LIST=/etc/apt/sources.list.d/docker.list
REPO="deb [arch=$ARCH signed-by=$KEYRING] https://download.docker.com/linux/ubuntu $CODENAME stable"
repo_changed=0

if [ -s "$KEYRING" ]; then
  log "docker apt key already installed: $KEYRING"
elif [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would fetch https://download.docker.com/linux/ubuntu/gpg -> $KEYRING"
  mark_change
else
  log "fetching Docker's apt signing key"
  install -m 0755 -d /etc/apt/keyrings
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmp now: the trap must know the path
  trap "rm -f '$tmp'" EXIT
  if curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o "$tmp" && [ -s "$tmp" ]; then
    install -o root -g root -m 0644 "$tmp" "$KEYRING"
    repo_changed=1
    mark_change
  else
    warn "could not fetch Docker's apt key (network?) — skipping Docker Engine"
    exit 0
  fi
fi

if [ -f "$LIST" ] && [ "$(cat "$LIST")" = "$REPO" ]; then
  log "docker apt source already up to date: $LIST"
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

# Only refresh when the source list actually changed — 10-apt-base.sh already
# ran apt-get update for this invocation.
if [ "$repo_changed" = 1 ]; then
  apt_update
fi

ensure_pkg \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# ── daemon ───────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would enable and start docker.service"
elif ! systemctl list-unit-files docker.service >/dev/null 2>&1 \
     || ! systemctl cat docker.service >/dev/null 2>&1; then
  warn "docker.service is not present — engine install did not complete"
else
  if systemctl is-enabled --quiet docker.service; then
    log "docker.service already enabled"
  else
    log "enabling docker.service"
    run systemctl enable docker.service
  fi
  if systemctl is-active --quiet docker.service; then
    log "docker.service already running"
  else
    log "starting docker.service"
    run systemctl start docker.service
  fi
fi

# ── group membership ─────────────────────────────────────────────────────────
# Without this every docker command needs sudo. Note the trade-off: the docker
# group can mount the host filesystem into a container as root, so it is
# effectively root-equivalent — the same bargain Docker's own docs describe.
DOCKER_USER="$(target_user 2>/dev/null || true)"
if [ -z "$DOCKER_USER" ]; then
  warn "cannot determine the target user — not touching the docker group"
elif ! id "$DOCKER_USER" >/dev/null 2>&1; then
  warn "configured user '$DOCKER_USER' does not exist here — not touching the docker group"
elif ! getent group docker >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would add $DOCKER_USER to the docker group"
  else
    warn "no docker group (engine not installed?) — not adding $DOCKER_USER"
  fi
elif id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx docker; then
  log "$DOCKER_USER is already in the docker group"
else
  log "adding $DOCKER_USER to the docker group (root-equivalent — see the note above)"
  run usermod -aG docker "$DOCKER_USER"
  log "log out and back in (or run 'newgrp docker') for the new group to apply"
fi
