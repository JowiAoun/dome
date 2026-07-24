#!/usr/bin/env bash
# 76-openwhispr.sh — OpenWhispr, the voice-to-text dictation app, from the
# vendor's own GitHub release.
#
# https://github.com/OpenWhispr/openwhispr — MIT, Electron, local Whisper /
# Parakeet models or cloud BYOK. Press a hotkey, speak, text lands at the cursor.
#
# Why the ROOT layer and not modules/apps.nix, where the other desktop apps live:
#
#   - nixpkgs does not have it. Checked, not assumed:
#       nix eval nixpkgs#openwhispr.version  ->  no such attribute
#     The apps module's table is a list of nixpkgs packages; there is nothing to
#     put in it.
#   - The vendor ships a .deb, and the README's Linux row lists
#     .AppImage/.deb/.rpm/.tar.gz as the supported downloads. On Ubuntu the .deb
#     is the one that integrates: dpkg tracks it, apt resolves its dependencies,
#     and it installs its own /usr/share/applications entry and icon — so unlike
#     every Nix app in this repo it needs none of the .desktop patching, and
#     GNOME finds it in the app grid by itself.
#   - Same reasoning as Brave (78-brave.sh): a package this large that ships its
#     own updates should not be frozen at whatever flake.lock last pointed at.
#
# Deliberately NOT pinned to the dash. It is hotkey-driven — you talk to it, you
# do not click it — so it stays in the app grid and out of the taskbar.
#
# Install method is exactly what the vendor documents for Debian/Ubuntu
# (docs.openwhispr.com/platform/linux):
#
#     sudo apt install ./OpenWhispr-*.deb
#
# apt, not `dpkg -i`: the package Depends on ydotool and libpipewire-0.3-0, and
# dpkg would leave it half-configured with no way to fetch them.
#
# ON by default in the template. Turn it off with `openWhispr = false;` in
# user-config.nix, or for a single run:  sudo bash system/run.sh --no-openwhispr
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

REPO="OpenWhispr/openwhispr"
BASE="https://github.com/$REPO/releases/latest/download"
MANIFEST_URL="$BASE/latest-linux.yml"

# The .deb's control field, read off the package itself rather than guessed —
# it is `open-whispr`, hyphenated, while everything user-facing is one word:
#   curl -r 0-262143 …-linux-amd64.deb | ar x - control.tar.xz  ->  Package: open-whispr
PKG="open-whispr"

# Disk. This is a ~1 GB application: the .deb is ~433 MB and its control block
# declares Installed-Size: 1008455 (≈ 985 MB). Both halves are checked below —
# once before downloading, once against the real Installed-Size before
# installing — because filling / is a far worse outcome than not having a
# dictation app. Headroom left over after installing, in KiB:
MIN_HEADROOM_KB=1048576   # 1 GiB

# user-config.nix is the source of truth; OPENWHISPR=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag openWhispr; then want=1; fi
case "${OPENWHISPR:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  log "OpenWhispr not requested — skipping (set openWhispr = true; in user-config.nix)"
  exit 0
fi

# The project publishes x64 Linux builds only — no arm64 .deb, .rpm, AppImage or
# tarball in the release. Their docs say so too ("x64 architecture").
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" != amd64 ]; then
  warn "OpenWhispr publishes x64 Linux builds only (this machine is $ARCH) — skipping"
  exit 0
fi

avail_kb() { df --output=avail / | tail -n1 | tr -d ' '; }
human_mb() { echo $(( ${1:-0} / 1024 )); }

# ── the bit their docs call "post-install" ───────────────────────────────────
# OpenWhispr types the transcript into whatever window has focus, and on Linux
# that needs a helper. Their platform guide names one per display server:
# xdotool for X11, wtype (or ydotool + ydotoold) for Wayland. The .deb Depends
# on ydotool so apt pulls that in either way, but ydotool needs a running
# ydotoold daemon and wtype does not — which makes wtype the one that works with
# no further setup.
#
# Both are installed rather than one: together they are well under a megabyte,
# and which display server this machine boots is not fixed (GNOME offers an Xorg
# session on the login screen). Getting it wrong means dictation silently pastes
# nothing, which is a miserable thing to debug.
#
# Done up here rather than after the install so it also self-heals a machine
# where OpenWhispr is already present and current — the run below exits early in
# that case and would never reach it.
ensure_pkg wtype xdotool

# ── what is published ────────────────────────────────────────────────────────
# electron-builder writes latest-linux.yml next to the binaries: the version,
# and for every artefact a size and a base64 sha512. It is a few hundred bytes,
# so asking "is there something newer?" costs nothing — which is what makes it
# safe to check on every run of a 433 MB download.
#
# It is also the vendor's own integrity data, published over HTTPS on the same
# release. That is a weaker guarantee than Brave's signed apt repository (see
# 78-brave.sh) — same origin, so it does not survive a compromised release — but
# it does catch a truncated or corrupted download, which is the realistic
# failure for a file this size.
tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # expand tmp now so the trap knows the path
trap "rm -rf '$tmp'" EXIT

if ! curl -fsSL --retry 3 "$MANIFEST_URL" -o "$tmp/latest-linux.yml"; then
  warn "could not fetch $MANIFEST_URL (network?) — skipping OpenWhispr"
  exit 0
fi

latest_version="$(awk '/^version:/ { print $2; exit }' "$tmp/latest-linux.yml")"
# The filename is read out of the manifest rather than assembled from the
# version, so a change in the vendor's naming cannot silently produce a 404.
deb_name="$(awk '/^[[:space:]]*-[[:space:]]*url:[[:space:]]*.*\.deb$/ { print $3; exit }' "$tmp/latest-linux.yml")"
deb_sha="$(awk '/^[[:space:]]*-[[:space:]]*url:[[:space:]]*.*\.deb$/ { found = 1; next }
                found && /sha512:/ { print $2; exit }' "$tmp/latest-linux.yml")"
deb_size="$(awk '/^[[:space:]]*-[[:space:]]*url:[[:space:]]*.*\.deb$/ { found = 1; next }
                 found && /^[[:space:]]*size:/ { print $2; exit }' "$tmp/latest-linux.yml")"

if [ -z "$latest_version" ] || [ -z "$deb_name" ] || [ -z "$deb_sha" ]; then
  warn "could not read a version, a .deb name and a checksum out of latest-linux.yml"
  warn "  the vendor may have changed the manifest format — skipping OpenWhispr"
  exit 0
fi

installed_version=""
pkg_installed "$PKG" && installed_version="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true)"

# `dpkg --compare-versions ge`, not string equality: the .deb's version could
# gain a revision suffix (1.7.6-1) without being a different release, and a
# string compare would then reinstall 433 MB on every single run.
if [ -n "$installed_version" ] && dpkg --compare-versions "$installed_version" ge "$latest_version"; then
  log "OpenWhispr $installed_version is installed and current (latest published: $latest_version)"
  exit 0
fi

if [ -n "$installed_version" ]; then
  log "OpenWhispr $installed_version installed, $latest_version published — upgrading"
else
  log "OpenWhispr $latest_version is not installed yet"
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would download $deb_name ($(human_mb $(( ${deb_size:-0} / 1024 ))) MB) and apt-get install it"
  mark_change
  exit 0
fi

# ── disk, before spending the download ───────────────────────────────────────
deb_kb=$(( ${deb_size:-454451196} / 1024 ))
need_kb=$(( deb_kb + 1048576 + MIN_HEADROOM_KB ))   # .deb + ~1 GiB unpacked + headroom
have_kb="$(avail_kb)"
if [ "$have_kb" -lt "$need_kb" ]; then
  warn "not enough free space on / for OpenWhispr"
  warn "  need about $(human_mb "$need_kb") MB, have $(human_mb "$have_kb") MB"
  warn "  it is a ~1 GB application (the .deb declares Installed-Size 1008455)"
  warn "  free some space and re-run 'sudo make system', or set openWhispr = false;"
  exit 0
fi

# ── download and verify ──────────────────────────────────────────────────────
log "downloading $deb_name ($(human_mb "$deb_kb") MB) — this takes a while"
if ! curl -fL --retry 3 --progress-bar "$BASE/$deb_name" -o "$tmp/$deb_name"; then
  warn "download failed (network?) — nothing was installed"
  exit 0
fi

# electron-builder records sha512 base64-encoded, not hex, so hash to raw bytes
# and encode the same way rather than trying to convert its digest.
got_sha="$(openssl dgst -sha512 -binary "$tmp/$deb_name" | base64 -w0)"
if [ "$got_sha" != "$deb_sha" ]; then
  warn "checksum MISMATCH for $deb_name — refusing to install"
  warn "  expected: $deb_sha"
  warn "  got:      $got_sha"
  warn "  nothing was changed. Retry; if it persists, the release may have been re-cut."
  exit 0
fi
log "checksum verified (sha512, from the vendor's latest-linux.yml)"

# Now that the package is on disk its real footprint is knowable, so re-check
# against that instead of the estimate above.
installed_size_kb="$(dpkg-deb -f "$tmp/$deb_name" Installed-Size 2>/dev/null || echo 0)"
have_kb="$(avail_kb)"
if [ "${installed_size_kb:-0}" -gt 0 ] &&
   [ "$have_kb" -lt $(( installed_size_kb + MIN_HEADROOM_KB )) ]; then
  warn "not enough free space to unpack OpenWhispr"
  warn "  it needs $(human_mb "$installed_size_kb") MB installed plus $(human_mb "$MIN_HEADROOM_KB") MB headroom, and / has $(human_mb "$have_kb") MB"
  warn "  the download has been discarded; nothing was installed"
  exit 0
fi

# ── install ──────────────────────────────────────────────────────────────────
# The local-file form, exactly as the vendor documents. The leading ./ is
# required — without it apt treats the argument as a package name.
log "installing OpenWhispr $latest_version"
if env DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$deb_name"; then
  mark_change
  log "OpenWhispr $(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || echo "$latest_version") installed"
else
  warn "apt could not install $deb_name (see the output above)"
  exit 0
fi

log "OpenWhispr is in the app grid — it is hotkey-driven, so it is deliberately not pinned to the dash"
log "  first launch walks through model download and hotkey setup"
