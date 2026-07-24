#!/usr/bin/env bash
# 78-brave.sh — Brave from Brave's own signed apt repository.
#
# Deliberately NOT the nixpkgs build. flake.lock freezes nixpkgs at whatever
# commit it was last bumped to, so a Nix Brave cannot receive a security update
# until somebody runs `make update`. This machine sat on Brave 143 — a Chromium
# seven months old — for exactly that reason, until sites started refusing it.
# A browser is the one package that must never be pinned, so it lives in the
# root layer, and every `sudo make system` upgrades it to the newest build Brave
# has published (see the upgrade step at the bottom) rather than merely leaving
# it eligible for an `apt upgrade` nobody runs.
#
# Its settings are configured separately, by 79-brave-policy.sh.
#
# The apps module notices (modules.apps.systemBrowser, wired from braveBrowser)
# and then installs no Nix Brave, pins this one, and points the web app
# launchers and $BROWSER at /usr/bin/brave-browser.
#
# ON by default in the template. Turn it off with `braveBrowser = false;` in
# user-config.nix, or for a single run:  sudo bash system/run.sh --no-brave
#
# Source: https://brave.com/linux/ — Debian/Ubuntu, amd64 and arm64.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

KEY_URL="https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"
KEY_PATH="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
LIST_PATH="/etc/apt/sources.list.d/brave-browser-release.sources"
LEGACY_LIST="/etc/apt/sources.list.d/brave-browser-release.list"
REPO_URI="https://brave-browser-apt-release.s3.brave.com/"

# Brave ships THREE keys in one keyring — they rotate and keep the old ones —
# so unlike Claude Desktop's single pin this compares the whole set.
#
# Note the weaker guarantee. Anthropic documents its fingerprint; Brave does
# not publish these anywhere machine-readable (brave.com/linux points at
# brave.com/signing-keys, whose static HTML contains none of the three —
# checked). So this pin is trust-on-first-use: it was established by fetching
# the documented keyring and confirming that the live dists/stable/InRelease is
# signed by the DBF1A116… key below. That does not prove the first fetch was
# honest, but it does turn any LATER key swap into a loud failure instead of
# silent trust for every future apt upgrade.
#
# If Brave legitimately adds a key this will refuse to proceed. Re-verify, then
# update the list:  gpg --show-keys --with-colons <the downloaded keyring>
EXPECTED_FPRS="47D32A74E9A9E013A4B4926C68D513D36A73CD96
B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0
DBF1A116C220B8C7164F98230686B78420038257"

# user-config.nix is the source of truth; BRAVE_BROWSER=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag braveBrowser; then want=1; fi
case "${BRAVE_BROWSER:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  log "Brave (apt) not requested — skipping (set braveBrowser = true; in user-config.nix)"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64 | arm64) ;;
  *)
    warn "Brave publishes amd64 and arm64 only (this machine is $ARCH) — skipping"
    exit 0
    ;;
esac

# Already installed? Then this run is an UPGRADE, not a no-op. Registering the
# repository is necessary but not sufficient: nothing on this machine runs
# `apt upgrade` on a schedule, so "it will update with apt" quietly meant
# "it will update the next time somebody remembers to". That is how a browser
# gets seven versions behind. The repository setup below is idempotent and
# costs nothing, so it runs either way — that is also what adopts a copy
# installed by hand from a downloaded .deb — and the run ends in the upgrade
# step at the bottom.
already=0
pkg_installed brave-browser && already=1

avail_kb="$(df --output=avail / | tail -n1 | tr -d ' ')"
if [ "$already" != 1 ] && [ "${avail_kb:-0}" -lt 2097152 ]; then
  warn "less than 2 GiB free on / — not installing Brave"
  warn "  free some space, then re-run 'sudo make system'"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  if [ "$already" = 1 ]; then
    log "DRY RUN: would refresh $REPO_URI and upgrade brave-browser to the newest published build"
  else
    log "DRY RUN: would install the signing key, register $REPO_URI and apt-get install brave-browser"
  fi
  mark_change
  exit 0
fi

# ── signing key ──────────────────────────────────────────────────────────────
if [ ! -f "$KEY_PATH" ]; then
  log "fetching Brave's package signing keyring"
  tmpkey="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmpkey now so the trap knows the path
  trap "rm -f '$tmpkey'" EXIT
  if ! curl -fsSL --retry 3 "$KEY_URL" -o "$tmpkey"; then
    warn "could not download the signing keyring (network?) — skipping Brave"
    exit 0
  fi
  [ -s "$tmpkey" ] || { warn "downloaded signing keyring is empty — skipping Brave"; exit 0; }

  # Verify before trusting. A mismatch is a hard stop, not a warning: installing
  # under an unexpected key would trust it for every later apt upgrade.
  if command -v gpg >/dev/null 2>&1; then
    got="$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | sort -u)"
    expected="$(printf '%s\n' "$EXPECTED_FPRS" | sort -u)"
    if [ -z "$got" ]; then
      warn "could not read any fingerprint from the downloaded keyring — skipping Brave"
      exit 0
    fi
    if [ "$got" != "$expected" ]; then
      warn "signing keyring fingerprints DO NOT MATCH — refusing to install Brave"
      warn "  expected:"
      printf '%s\n' "$expected" | sed 's/^/    /' >&2
      warn "  got:"
      printf '%s\n' "$got" | sed 's/^/    /' >&2
      warn "  nothing was changed. If Brave rotated keys, re-verify against"
      warn "  https://brave.com/signing-keys/ and update EXPECTED_FPRS here."
      exit 0
    fi
    nkeys="$(printf '%s\n' "$got" | wc -l | tr -d ' ')"
    log "signing keyring verified ($nkeys keys)"
  else
    warn "gpg is not installed — cannot verify the signing keyring fingerprints"
    warn "  installing anyway; verify later with: gpg --show-keys $KEY_PATH"
  fi

  install -o root -g root -m 0644 "$tmpkey" "$KEY_PATH"
  mark_change
else
  log "signing keyring already installed: $KEY_PATH"
fi

# ── repository ───────────────────────────────────────────────────────────────
# deb822, which is what brave.com/linux now documents. Written here rather than
# curl'd from their server so the contents are deterministic and Signed-By
# always points at the keyring verified above.
#
# Suites/Components/Architectures are taken from the live index, not guessed:
#   Origin: Brave Software / Codename: stable / Components: main
#   Architectures: amd64 arm64
read -r -d '' LIST_BODY <<EOF || true
Types: deb
URIs: $REPO_URI
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: $KEY_PATH
EOF

# An older install of Brave leaves a one-line .list behind. Left in place it
# would define the same repo twice and apt would warn on every update.
if [ -f "$LEGACY_LIST" ]; then
  log "removing the superseded $LEGACY_LIST (replaced by the deb822 .sources)"
  rm -f "$LEGACY_LIST"
  mark_change
fi

if [ -f "$LIST_PATH" ] && [ "$(cat "$LIST_PATH")" = "$LIST_BODY" ]; then
  log "apt repository already registered: $LIST_PATH"
else
  log "registering Brave's apt repository"
  printf '%s\n' "$LIST_BODY" > "$LIST_PATH"
  chmod 0644 "$LIST_PATH"
  mark_change
  # The index for the new repository has to exist before the install below.
  FORCE_APT_UPDATE=1 apt_update
fi

# ── package ──────────────────────────────────────────────────────────────────
brave_version() { dpkg-query -W -f='${Version}' brave-browser 2>/dev/null || true; }

# Refresh THIS repository's index and nothing else, so "always the latest" holds
# however the script was entered — including `sudo bash system/78-brave.sh` on
# its own, which never reaches 10-apt-base.sh's apt-get update.
#
# A plain `apt-get update` would re-fetch every repository on the machine (tens
# of seconds on a cold cache) to answer a question about one of them. Pointing
# sourceparts at a directory holding nothing but Brave's .sources restricts it
# to the one index that matters, which takes about a second. List-Cleanup=0 is
# not optional: without it apt sees the other repositories missing from this
# restricted view, decides their cached lists are orphaned, and deletes them —
# so the next unrelated `apt install` would have to re-download everything.
refresh_brave_index() {
  local dir rc=0
  dir="$(mktemp -d)"
  cp "$LIST_PATH" "$dir/" || { rm -rf "$dir"; return 1; }
  apt-get update \
    -o Dir::Etc::sourcelist=/dev/null \
    -o Dir::Etc::sourceparts="$dir" \
    -o APT::Get::List-Cleanup=0 >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  return "$rc"
}

if [ "$already" = 1 ]; then
  before="$(brave_version)"
  log "Brave $before installed — checking Brave's repository for a newer build"
  refresh_brave_index || warn "could not refresh Brave's package index (network?) — using the cached one"

  if env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade brave-browser; then
    after="$(brave_version)"
    if [ "$after" != "$before" ]; then
      log "Brave upgraded: $before -> $after (restart the browser to pick it up)"
      mark_change
    else
      log "Brave is already the newest published build ($after)"
    fi
  else
    warn "apt could not upgrade brave-browser (see the output above)"
    warn "  $before is still installed and working; retry with: sudo apt update && sudo apt install --only-upgrade brave-browser"
  fi
  exit 0
fi

log "installing Brave"
if env DEBIAN_FRONTEND=noninteractive apt-get install -y brave-browser; then
  mark_change
  log "Brave $(brave_version) installed — every 'sudo make system' from now on upgrades it to the newest build"
else
  warn "apt could not install brave-browser (see the output above)"
  warn "  the repository is registered; retry with: sudo apt update && sudo apt install brave-browser"
  exit 0
fi
