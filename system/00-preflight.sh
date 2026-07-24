#!/usr/bin/env bash
# 00-preflight.sh — read-only sanity checks before the system layer runs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

[ -r /etc/os-release ] || die "/etc/os-release missing — unsupported system"
. /etc/os-release

if [ "${ID:-}" != ubuntu ]; then
  [ "${FORCE:-0}" = 1 ] || die "this system layer targets Ubuntu (found: ${ID:-unknown}). FORCE=1 to override."
  warn "running on ${ID:-unknown} with FORCE=1"
fi

# The two LTS releases this layer is known to work on: 24.04 (noble), where it
# was written, and 26.04 (resolute), its successor. Both were checked rather
# than assumed compatible — the two things that are actually release-specific
# both hold on resolute:
#
#   - 20-kernel.sh needs an HWE metapackage for the release. It no longer
#     hardcodes one, and linux-generic-hwe-26.04 is published (7.0.0-28.28).
#   - 60-docker.sh builds Docker's apt suite from the codename, and
#     download.docker.com/linux/ubuntu/dists/resolute/InRelease exists.
#
# Interim (non-LTS) releases stay behind FORCE=1 on purpose: they are supported
# for nine months, which is shorter than the gap between provisions of this
# machine, so a system layer aimed at one would rot in place.
case "${VERSION_ID:-}" in
  24.04 | 26.04) log "Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-unknown})" ;;
  *)
    [ "${FORCE:-0}" = 1 ] || die "expected Ubuntu 24.04 or 26.04 (LTS), found ${VERSION_ID:-unknown}. FORCE=1 to override."
    warn "running on Ubuntu ${VERSION_ID:-unknown} with FORCE=1 — 20-kernel.sh falls back to the GA kernel if there is no HWE stack for it"
    ;;
esac

# Refuse to run inside a live-USB session: casper/overlay roots mean nothing
# persists. (Use 'duo doctor' from the live session instead — it's read-only.)
if grep -qE 'casper|/cow |/rofs ' /proc/mounts; then
  die "live-USB session detected — run the system layer on the installed OS only"
fi

if [ ! -d /sys/firmware/efi ]; then
  warn "not booted via UEFI — GRUB/ESP dual-boot assumptions do not apply here"
fi

if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  die "another package manager holds the apt/dpkg lock — retry after it finishes"
fi

avail_kb="$(df --output=avail / | tail -n1 | tr -d ' ')"
if [ "${avail_kb:-0}" -lt 2097152 ]; then
  warn "less than 2 GiB free on / — kernel installs may fail"
fi

log "preflight OK"
