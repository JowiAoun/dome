#!/usr/bin/env bash
# 74-hyperframes.sh: HyperFrames Studio, HeyGen's app for making videos out of
# HTML with an agent, from the vendor's own .deb.
#
# https://github.com/heygen-com/hyperframes (Apache 2.0). nixpkgs has no
# hyperframes package, and the vendor ships a .deb for Linux, so it is a
# root-layer install like OpenWhispr (76-openwhispr.sh). The .deb brings its own
# launcher and icon, and its own AppArmor profile (userns only), which an
# Electron app needs to start on Ubuntu 24.04.
#
# latest.json, next to the downloads, names the newest build with its size and
# sha256. This installs that build, checked against that sha256. After that the
# app keeps itself current: it reads the same file and asks for your password
# to run apt-get on the new .deb. A run here only downloads when the installed
# build is older.
#
# Turn it off with `hyperframes = false;` in user-config.nix, or for a single
# run:  sudo bash system/run.sh --no-hyperframes
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

MANIFEST_URL="https://static.heygen.ai/hyperframes-oss/desktop/latest.json"
# Read off the .deb itself: `dpkg-deb -f HyperFrames-amd64.deb Package`.
PKG="hyperframes"
# Free space to leave on / after installing, in KiB.
MIN_HEADROOM_KB=1048576

# user-config.nix is the source of truth. HYPERFRAMES=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges).
want=0
if config_flag hyperframes; then want=1; fi
case "${HYPERFRAMES:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

if [ "$want" != 1 ]; then
  log "HyperFrames not requested, skipping (set hyperframes = true; in user-config.nix)"
  exit 0
fi

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" != amd64 ]; then
  warn "HyperFrames publishes its .deb for amd64 only (this machine is $ARCH), skipping"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 is missing, so latest.json cannot be read, skipping HyperFrames"
  exit 0
fi

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # expand tmp now so the trap knows the path
trap "rm -rf '$tmp'" EXIT

if ! curl -fsSL --retry 3 "$MANIFEST_URL" -o "$tmp/latest.json"; then
  warn "could not fetch $MANIFEST_URL (network?), skipping HyperFrames"
  exit 0
fi

# The .deb's url, size in bytes, sha256 and build, one per line.
mapfile -t deb < <(python3 -I - "$tmp/latest.json" <<'PY' 2>/dev/null || true
import json, sys
deb = json.load(open(sys.argv[1])).get("deb") or {}
for key in ("url", "bytes", "sha256", "build"):
    print(deb.get(key, ""))
PY
)
deb_url="${deb[0]:-}" deb_size="${deb[1]:-}" deb_sha="${deb[2]:-}" deb_build="${deb[3]:-}"

if [[ ! "$deb_url" =~ ^https://static\.heygen\.ai/hyperframes-oss/desktop/[A-Za-z0-9._-]+\.deb$ ]] ||
   [[ ! "$deb_size" =~ ^[0-9]+$ ]] || [[ ! "$deb_sha" =~ ^[0-9a-f]{64}$ ]] ||
   [[ ! "$deb_build" =~ ^b[0-9]+$ ]]; then
  warn "latest.json does not name a .deb with a size, a sha256 and a build"
  warn "  the vendor may have changed its format, skipping HyperFrames"
  exit 0
fi

# The package version carries the build: 0.1.0+b806.
installed=""
pkg_installed "$PKG" && installed="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true)"
have_build="$(sed -n 's/.*+b\([0-9][0-9]*\)$/\1/p' <<< "$installed")"

if [ -n "$have_build" ] && [ "$have_build" -ge "${deb_build#b}" ]; then
  log "HyperFrames $installed is installed and current (latest build: $deb_build)"
  exit 0
fi

if [ -n "$installed" ]; then
  log "HyperFrames $installed installed, build $deb_build published, upgrading"
else
  log "HyperFrames build $deb_build is not installed yet"
fi

deb_kb=$(( deb_size / 1024 ))
if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would download ${deb_url##*/} ($(( deb_kb / 1024 )) MB) and apt-get install it"
  mark_change
  exit 0
fi

avail_kb() { df --output=avail / | tail -n1 | tr -d ' '; }

# Before the download: the .deb, about 4 times its size unpacked, and headroom.
need_kb=$(( deb_kb * 5 + MIN_HEADROOM_KB ))
if [ "$(avail_kb)" -lt "$need_kb" ]; then
  warn "not enough free space on / for HyperFrames"
  warn "  need about $(( need_kb / 1024 )) MB, have $(( $(avail_kb) / 1024 )) MB"
  exit 0
fi

log "downloading ${deb_url##*/} ($(( deb_kb / 1024 )) MB)"
if ! curl -fL --retry 3 --progress-bar "$deb_url" -o "$tmp/hyperframes.deb"; then
  warn "download failed (network?), nothing was installed"
  exit 0
fi

got_sha="$(sha256sum "$tmp/hyperframes.deb" | cut -d' ' -f1)"
if [ "$got_sha" != "$deb_sha" ]; then
  warn "checksum MISMATCH for ${deb_url##*/}, refusing to install"
  warn "  expected: $deb_sha"
  warn "  got:      $got_sha"
  exit 0
fi
log "checksum verified (sha256, from the vendor's latest.json)"

if [ "$(dpkg-deb -f "$tmp/hyperframes.deb" Package 2>/dev/null)" != "$PKG" ]; then
  warn "the download is not the $PKG package, refusing to install"
  exit 0
fi

# Now the real unpacked size is known.
installed_size_kb="$(dpkg-deb -f "$tmp/hyperframes.deb" Installed-Size 2>/dev/null || echo 0)"
if [ "$(avail_kb)" -lt $(( ${installed_size_kb:-0} + MIN_HEADROOM_KB )) ]; then
  warn "not enough free space to unpack HyperFrames ($(( ${installed_size_kb:-0} / 1024 )) MB plus headroom)"
  exit 0
fi

# apt, not dpkg -i, so the libraries it Depends on are installed too. The path
# starts with /, which is what makes apt read it as a file.
log "installing HyperFrames build $deb_build"
if env DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/hyperframes.deb"; then
  mark_change
  log "HyperFrames $(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null) installed"
else
  warn "apt could not install ${deb_url##*/} (see the output above)"
  exit 0
fi
