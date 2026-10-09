#!/usr/bin/env bash
# 84-media.sh — the GStreamer decoders Ubuntu's desktop seed leaves out.
#
# WHAT IS ALREADY HERE, and why this script is so small. `ubuntu-restricted-
# addons` ships with the desktop install and pulls in gstreamer1.0-plugins-good,
# -ugly and -libav, which between them decode MP3, AAC, H.264 and essentially
# every MP4 a browser or a phone produces. So "Ubuntu cannot play MP3" has not
# been true for years, and adding `ubuntu-restricted-extras` on top buys only
# the Microsoft core fonts and unrar — no codecs this machine does not have.
#
# What a fresh 24.04 is ACTUALLY missing is an application to open the file
# with: `xdg-mime query default audio/mpeg` and `video/mp4` both come back empty
# on a stock install, because no player is seeded at all. That gap is not fixed
# here — VLC comes from Flathub via `flatpakApps` in user-config.nix (see
# system/82-flatpak.sh), and the default handlers are registered by
# modules/apps.nix. This file is only about the decoders underneath.
#
# WHAT IS MISSING from the seed is plugins-bad. "bad" is upstream's statement
# about code maturity and test coverage, NOT about licensing — these are ordinary
# universe packages and carry no legal question that -ugly did not already carry.
# It is where the demuxers live:
#
#   hlsdemux / dashdemux   HLS and MPEG-DASH — most streaming video on the web
#   tsdemux                MPEG-TS: .ts files and anything recorded off a tuner
#   asfdemux               the .wmv/.asf containers
#   faad, opus, mpeg2      codec gaps around the edges of what -good covers
#
# WHAT THIS REACHES, AND WHAT IT DOES NOT. GStreamer is the SYSTEM media stack,
# so this fixes video thumbnails in Files, GNOME's own players, GTK apps, and
# anything Nix-installed that links gstreamer. It does NOTHING for the Flatpak
# VLC, which ships its own decoders inside the sandbox, and nothing for Brave or
# Firefox, which bundle their own ffmpeg. That is the honest scope: it closes the
# "this one file will not play / has no thumbnail" cases in the desktop itself,
# and it is why installing it is worth ~10 MB but is not the answer to "I cannot
# play this MP4" — that answer is a player.
#
# ON UBUNTU PRO. With Pro attached, apt prefers esm-apps' +esm1 build (priority
# 510) over the identical universe one (500). Both exist here, so this installs
# with or without a subscription; Pro only decides which pocket it is served
# from and whether it keeps getting security updates after universe stops.
#
# NO SWITCH, matching 83-qt-runtime.sh. This is a dependency of a working
# desktop rather than a preference — there is no version of "I have a GNOME
# desktop and would like fewer file formats to work" — so instead of a flag it
# detects that there is no desktop media stack to extend and says so.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

# WSL has no desktop, no thumbnailer and no player, so a decoder plugin there
# has nothing to decode for. Same guard, and the same reason, as 82-flatpak.sh.
if out_matches "$(cat /proc/version 2>/dev/null || true)" -i microsoft; then
  log "WSL detected — skipping media codecs (no desktop media stack to extend)"
  exit 0
fi

# The presence of the GStreamer core is the test for "is there a desktop media
# stack here at all?". On a headless or minimal box there is none, and pulling
# a plugin set in would drag the whole core along with it for nothing to use.
if ! pkg_installed libgstreamer1.0-0; then
  log "gstreamer is not installed — skipping media codecs (nothing would load them)"
  log "  this is expected on a server or minimal install; a desktop has it already"
  exit 0
fi

ensure_pkg gstreamer1.0-plugins-bad

log "media codecs ready. To check what can decode a given format:"
log "  gst-inspect-1.0 | grep -i <codec>          is the element present"
log "  gst-discoverer-1.0 <file>                  what the stack makes of a file"
log "  a player still has to be installed separately — see flatpakApps in user-config.nix"
