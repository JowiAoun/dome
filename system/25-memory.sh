#!/usr/bin/env bash
# 25-memory.sh — make the machine survive running out of RAM, instead of
# dropping you at the login screen.
#
# The failure it fixes, from this machine's journal (2026-07-24):
#
#   systemd-oomd[1387]: Killed
#     /user.slice/user-1000.slice/user@1000.service/session.slice/org.gnome.Shell@wayland.service
#     due to memory pressure for /user.slice/user-1000.slice/user@1000.service
#     being 58.86% > 50.00% for > 20s with reclaim activity
#
# On Wayland gnome-shell IS the session: killing it takes every open app with
# it, so this reads as "the computer crashed" even though nothing crashed.
#
# The chain that got there, with modded Minecraft (8 GB Java heap, ~10 GB RSS)
# plus a browser and a chat client on a 15 GiB machine whose iGPU has no
# dedicated VRAM:
#   1. Ubuntu ships /usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf
#      with ManagedOOMMemoryPressure=kill at a 50% pressure limit.
#   2. Only 4 GB of swap sat behind 15 GiB of RAM, on dm-crypt, with stock
#      reclaim tuning — so pressure built fast and stayed high.
#   3. systemd-oomd picks the descendant cgroup with the HIGHEST PRESSURE, not
#      the biggest one. The 10 GB JVM has already faulted its heap in and sits
#      quiet; the compositor is the thing actively trying to allocate.
#   4. Which is why alt-tabbing was the trigger: leaving the game makes
#      gnome-shell allocate (overview, window thumbnails, compositing resumes)
#      at the exact moment nothing is free. It spikes its own PSI and elects
#      itself as the victim.
#
# So this script does four things, in the order they matter:
#   zram        a compressed swap tier in RAM, so reclaim is microseconds
#               instead of a trip through LUKS to NVMe and pressure never
#               builds to the trigger in the first place
#   swapfile    4 GB -> 16 GB of real overflow behind zram
#   sysctl      reclaim tuning that assumes swap is fast (it now is)
#   cgroups     MemoryHigh on app.slice so apps cannot squeeze the session out,
#               plus the oomd settings that stop the desktop being the victim
#
# Why the root layer and not Nix: /etc/sysctl.d, /etc/systemd/system and the
# swapfile are all root-owned system state that home-manager does not manage.
# The gnome-shell and app.slice drop-ins go in /etc/systemd/user/, the
# system-wide directory for USER units — root-owned config for a user unit,
# which keeps the whole story in one file you can read, revert and reason about.
#
# Unconditional on purpose: there is no user-config.nix switch for this. It is
# a correctness fix, not a preference — every machine this repo provisions is
# better off with it, and each section self-skips when it has nothing to do.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

ZRAM_CONF=/etc/systemd/zram-generator.conf
SYSCTL_CONF=/etc/sysctl.d/90-dome-memory.conf
OOMD_DROPIN=/etc/systemd/system/user@.service.d/50-dome-oomd.conf
APP_SLICE_DROPIN=/etc/systemd/user/app.slice.d/50-dome-memory.conf
SHELL_DROPINS=(
  /etc/systemd/user/org.gnome.Shell@wayland.service.d/50-dome-oomd.conf
  /etc/systemd/user/org.gnome.Shell@x11.service.d/50-dome-oomd.conf
)

SWAPFILE=/swap.img
SWAP_TARGET_GB=16

# Set by install_conf; read at the end to decide what needs reloading.
SYSTEMD_CHANGED=0

TMPD="$(mktemp -d)"
# shellcheck disable=SC2064  # expand TMPD now so the trap knows the path
trap "rm -rf '$TMPD'" EXIT

# Install a generated config file iff its content differs.
# Returns 0 ("true") when it wrote something, 1 when the file was already
# correct — so callers can do `if install_conf ...; then <reload>; fi` and only
# pay for a reload when one is actually needed. Always call it in a conditional
# context: a bare call returning 1 would abort the script under `set -e`.
install_conf() {
  local path="$1" body="$2" tmp="$TMPD/conf"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$body" ]; then
    log "up to date: $path"
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would write $path"
    mark_change
    return 0
  fi
  log "writing $path"
  install -d -o root -g root -m 0755 "$(dirname "$path")"
  printf '%s\n' "$body" > "$tmp"
  install -o root -g root -m 0644 "$tmp" "$path"
  mark_change
  return 0
}

# ── 1. zram: the fast swap tier ──────────────────────────────────────────────
# Compressed swap that lives in RAM. Anonymous pages go in at ~3:1 on a Java
# heap, so ~7.5 GiB of swapped pages cost ~2.5 GiB of real memory — a net gain
# of several GB, at RAM latency rather than encrypted-NVMe latency. That speed
# is the point: reclaim that completes in microseconds never lets the pressure
# average climb to the level that made oomd fire.
#
# systemd-zram-generator rather than zram-tools: it is a systemd generator, so
# the device is a real swap unit with a proper ordering and no init script.

# The package lives in universe and may not be published everywhere this repo
# runs. Same two-signal check as 20-kernel.sh uses for the HWE metapackage:
# apt-cache prints a stanza for virtual/dropped packages too, with
# "Candidate: (none)", and stale lists read the same way as genuinely absent.
#
# Deliberately NOT `apt-cache policy ... | grep -q`: lib.sh sets pipefail, and
# `grep -q` exits at the first match, which SIGPIPEs apt-cache while it still
# has the version table to write. The pipeline then returns 141 and a package
# that IS published reads as missing. Capture first, match the string.
zram_available() {
  if pkg_installed systemd-zram-generator; then
    return 0
  fi
  local policy
  policy="$(apt-cache policy systemd-zram-generator 2>/dev/null || true)"
  grep -qE '^[[:space:]]+Candidate: [^([:space:]]' <<<"$policy"
}

if ! zram_available; then apt_update; fi

if ! zram_available; then
  warn "systemd-zram-generator is not published here — skipping the zram tier"
  warn "  the swapfile, sysctl and cgroup sections below still apply"
else
  ensure_pkg systemd-zram-generator

  read -r -d '' ZRAM_BODY <<'EOF' || true
# Managed by dome (system/25-memory.sh) — regenerated on every run.
#
# A compressed swap device in RAM, tried before the disk swapfile. See the
# header of system/25-memory.sh for why this exists.
[zram0]
# Half of RAM, capped at 8 GiB. The expression form (rather than a literal) is
# what keeps this sane on a machine with 8 GB or with 64 GB.
zram-size = min(ram / 2, 8192)
# zstd compresses a Java heap far better than the lzo-rle default, and the CPU
# cost is invisible next to a page fault that would otherwise reach the disk.
compression-algorithm = zstd
# Above the swapfile's default priority of -1, so zram fills first and the disk
# only takes what zram could not hold.
swap-priority = 100
fs-type = swap
EOF

  if install_conf "$ZRAM_CONF" "$ZRAM_BODY"; then
    zram_conf_changed=1
  else
    zram_conf_changed=0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would activate dev-zram0.swap"
  else
    # daemon-reload re-runs the generator, which is what materialises the unit.
    systemctl daemon-reload
    # Read /proc/swaps directly rather than `swapon | grep -q`: same pipefail
    # SIGPIPE trap as zram_available above, and here a false negative would
    # re-report "activated" on every run and break the idempotency contract.
    if awk '$1 == "/dev/zram0" { found = 1 } END { exit !found }' /proc/swaps; then
      if [ "$zram_conf_changed" = 1 ]; then
        # Deliberately not restarting: that means swapoff on a device holding
        # live pages, which is exactly the memory spike this script exists to
        # avoid. The new size is picked up at the next boot.
        log "zram0 is already active — the new settings apply at the next boot"
      else
        log "zram0 already active"
      fi
    # dev-zram0.swap, NOT systemd-zram-setup@zram0.service: the setup service
    # only creates and mkswaps the device. The .swap unit is what actually
    # swapons it, and it pulls the setup service in through Requires= — so
    # starting the setup service alone leaves a configured-but-unused zram
    # until the next boot, which looks like it worked and does nothing.
    elif systemctl start dev-zram0.swap 2>/dev/null; then
      log "zram0 activated"
      mark_change
    else
      warn "could not start dev-zram0.swap — no zram tier"
      warn "  retry with:  sudo systemctl start dev-zram0.swap"
      warn "  (it is wanted by swap.target, so a reboot brings it up either way)"
    fi
  fi
fi

# ── 2. swapfile: 4 GB -> 16 GB of overflow ───────────────────────────────────
# Not for hibernation (docs/PLAN.md D8: this machine is s2idle-only). This is
# purely the tier behind zram, for pages cold enough that compressing them in
# RAM is a waste of RAM — a browser's idle heap, a chat client in the tray.
swap_want_bytes=$((SWAP_TARGET_GB * 1024 * 1024 * 1024))

resize_swapfile() {
  swapoff "$SWAPFILE" || { warn "swapoff $SWAPFILE failed — leaving it alone"; return 1; }
  rm -f "$SWAPFILE"
  # From here on the machine has no disk swap until we finish, so every step
  # reports precisely what to re-run by hand if it fails.
  if ! fallocate -l "${SWAP_TARGET_GB}G" "$SWAPFILE"; then
    warn "fallocate failed — recreate it with:"
    warn "  sudo fallocate -l ${SWAP_TARGET_GB}G $SWAPFILE && sudo chmod 600 $SWAPFILE && sudo mkswap $SWAPFILE && sudo swapon $SWAPFILE"
    return 1
  fi
  chmod 600 "$SWAPFILE"
  if ! mkswap "$SWAPFILE" >/dev/null; then
    warn "mkswap failed — finish with:  sudo mkswap $SWAPFILE && sudo swapon $SWAPFILE"
    return 1
  fi
  if ! swapon "$SWAPFILE"; then
    warn "swapon failed — enable it with:  sudo swapon $SWAPFILE"
    return 1
  fi
  return 0
}

swap_fstype="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"

if [ ! -f "$SWAPFILE" ]; then
  log "$SWAPFILE is not a regular file (swap partition, or no swap) — leaving swap alone"
elif [ "$swap_fstype" != ext4 ]; then
  # fallocate's preallocated extents are safe to swapon on ext4, which is what
  # Ubuntu's own installer does. btrfs needs `btrfs filesystem mkswapfile`, xfs
  # needs a different dance again — none of which is worth guessing at.
  log "root filesystem is $swap_fstype, not ext4 — not resizing $SWAPFILE"
else
  swap_cur_bytes="$(stat -c %s "$SWAPFILE")"
  if [ "$swap_cur_bytes" -ge "$swap_want_bytes" ]; then
    log "$SWAPFILE is already $((swap_cur_bytes / 1024 / 1024 / 1024)) GB — no resize needed"
  else
    # swapoff pages everything on the file back INTO RAM. Doing that when there
    # is no room for it would OOM the machine mid-provision, so refuse instead.
    swap_used_kb="$(awk -v f="$SWAPFILE" '$1 == f { print $4 }' /proc/swaps)"
    swap_used_kb="${swap_used_kb:-0}"
    mem_avail_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
    disk_free_kb="$(df -Pk / | awk 'NR == 2 { print $4 }')"
    disk_need_kb=$(( (swap_want_bytes - swap_cur_bytes) / 1024 + 4 * 1024 * 1024 ))

    if [ "$swap_used_kb" -gt $((mem_avail_kb - 1024 * 1024)) ]; then
      warn "$SWAPFILE holds $((swap_used_kb / 1024)) MB but only $((mem_avail_kb / 1024)) MB of RAM is available"
      warn "  not resizing: swapoff would have to page all of that back in"
      warn "  re-run 'sudo make system' on a freshly booted machine"
    elif [ "$disk_free_kb" -lt "$disk_need_kb" ]; then
      warn "only $((disk_free_kb / 1024 / 1024)) GB free on / — need ~$((disk_need_kb / 1024 / 1024)) GB to grow $SWAPFILE"
    elif [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would grow $SWAPFILE from $((swap_cur_bytes / 1024 / 1024 / 1024)) GB to ${SWAP_TARGET_GB} GB"
      mark_change
    else
      log "growing $SWAPFILE from $((swap_cur_bytes / 1024 / 1024 / 1024)) GB to ${SWAP_TARGET_GB} GB"
      if resize_swapfile; then
        log "$SWAPFILE is now ${SWAP_TARGET_GB} GB"
        mark_change
      fi
      # /etc/fstab already names $SWAPFILE by path with no size in it, so a
      # resize needs no fstab change and survives a reboot as-is.
    fi
  fi
fi

# ── 3. reclaim tuning ────────────────────────────────────────────────────────
read -r -d '' SYSCTL_BODY <<'EOF' || true
# Managed by dome (system/25-memory.sh) — regenerated on every run.
#
# Reclaim tuning for a machine whose first swap tier is zram. See the header of
# system/25-memory.sh.

# The default of 60 encodes "swapping is a trip to a disk". zram is RAM, so
# reclaiming an anonymous page is cheaper than dropping a page of file cache we
# would only have to read back. 180 is the value the zram-by-default distros
# (Fedora, ChromeOS, Pop!_OS) settled on; the ceiling is 200.
vm.swappiness = 180

# Watermark boosting kicks off an extra reclaim burst to fight fragmentation.
# On a laptop that allocates in bursts it mostly produces latency spikes — and
# a latency spike under load is precisely what pushes the PSI average over
# oomd's threshold. Off.
vm.watermark_boost_factor = 0

# How much headroom kswapd keeps ahead of an allocation, in units of 0.01% of
# RAM. The default 10 is 0.1% — about 15 MB here, which a single frame's worth
# of allocations blows straight through, so reclaim always starts already late
# and allocations stall. 125 is 1.25%, about 190 MB of runway.
vm.watermark_scale_factor = 125

# Swap readahead, as a power of two. The default 3 reads 8 pages at a time,
# which is right for a disk with seek costs to amortise and wrong for zram:
# it decompresses 7 pages nobody asked for and wastes the space they occupy.
vm.page-cluster = 0

# NOTE: vm.max_map_count is deliberately absent. Ubuntu 24.04 already defaults
# it to 1048576 — the value mod-heavy games are usually told to set by hand —
# so pinning it here would only create a second place to be wrong.
EOF

if install_conf "$SYSCTL_CONF" "$SYSCTL_BODY"; then
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would apply $SYSCTL_CONF"
  elif sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1; then
    log "reclaim tuning applied"
  else
    warn "could not apply $SYSCTL_CONF — it still takes effect at the next boot"
    warn "  retry with:  sudo sysctl -p $SYSCTL_CONF"
  fi
fi

# ── 4. cgroups: who gets squeezed, and who never gets killed ─────────────────
# Three drop-ins that together turn "the session dies" into "the game gets
# slow". Read them in this order.

# (a) app.slice is where gnome-shell puts everything you launch — the game, the
# browser, the chat client. MemoryHigh is a THROTTLE, not a limit: past it the
# kernel reclaims hard from inside app.slice instead of taking pages from the
# session. Nothing is killed. 12G of 15 GiB leaves the desktop, the system
# services and the iGPU's own allocations a floor they cannot be pushed below.
#
# It also fixes oomd's aim for free: the reclaim pressure now shows up inside
# app.slice, so the highest-pressure cgroup is an app rather than the compositor.
read -r -d '' APP_SLICE_BODY <<'EOF' || true
# Managed by dome (system/25-memory.sh) — regenerated on every run.
[Slice]
MemoryHigh=12G
EOF

# (b) Ubuntu's 50% pressure limit is aggressive for a desktop that is supposed
# to be allowed to use its RAM. 75% still catches a genuine runaway, but no
# longer fires during the ordinary "big game plus a browser" case that the
# sections above now absorb.
read -r -d '' OOMD_BODY <<'EOF' || true
# Managed by dome (system/25-memory.sh) — regenerated on every run.
# Overrides /usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf.
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=75%
EOF

# (c) And if oomd does fire, it must never choose the compositor. `omit` takes
# the unit out of candidate selection entirely (systemd sets a user.oomd_omit
# xattr on the cgroup, which systemd-oomd reads). Both template instances,
# because which one runs depends on the session type.
read -r -d '' SHELL_BODY <<'EOF' || true
# Managed by dome (system/25-memory.sh) — regenerated on every run.
#
# On Wayland gnome-shell IS the session: if systemd-oomd kills it, every open
# application dies with it and you land at the login screen. Never a candidate.
[Service]
ManagedOOMPreference=omit
EOF

if install_conf "$APP_SLICE_DROPIN" "$APP_SLICE_BODY"; then SYSTEMD_CHANGED=1; fi
if install_conf "$OOMD_DROPIN" "$OOMD_BODY"; then SYSTEMD_CHANGED=1; fi
for dropin in "${SHELL_DROPINS[@]}"; do
  if install_conf "$dropin" "$SHELL_BODY"; then SYSTEMD_CHANGED=1; fi
done

# ── 5. reload ────────────────────────────────────────────────────────────────
if [ "$SYSTEMD_CHANGED" != 1 ]; then
  log "cgroup and oomd settings unchanged — nothing to reload"
elif [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would reload systemd and restart systemd-oomd"
else
  # daemon-reload is enough, and systemd-oomd is deliberately NOT restarted.
  #
  # oomd does not read unit files: PID 1 pushes it the set of cgroups to watch
  # over the io.systemd.ManagedOOM varlink socket, and re-sends on reload. A
  # restart throws that live subscription away — and measured on this machine,
  # the system-level entry did not come back. `oomctl` listed only the user
  # manager's own scopes (which re-register themselves as they come and go),
  # with user@1000.service missing entirely, i.e. no pressure monitoring at the
  # level this drop-in configures. Reloading alone leaves the running oomd
  # subscribed and simply updates it.
  systemctl daemon-reload

  # The app.slice and gnome-shell drop-ins belong to the USER manager, which
  # root's daemon-reload does not reach. Reload it in place so the settings
  # apply to the running session instead of waiting for the next login.
  reload_user=""
  if reload_user="$(target_user 2>/dev/null)" && [ -n "$reload_user" ]; then
    reload_uid="$(id -u "$reload_user" 2>/dev/null || true)"
  fi
  if [ -n "${reload_uid:-}" ] && [ -d "/run/user/$reload_uid" ] \
     && runuser -u "$reload_user" -- \
          env "XDG_RUNTIME_DIR=/run/user/$reload_uid" systemctl --user daemon-reload 2>/dev/null; then
    log "user manager reloaded — app.slice and gnome-shell settings are live"
  elif [ -z "${reload_user:-}" ]; then
    warn "cannot determine the target user — not reloading any user manager"
    warn "  the app.slice and gnome-shell settings apply at the next login"
  else
    warn "could not reach $reload_user's systemd user manager (not logged in?)"
    warn "  the settings apply at the next login, or run as that user:"
    warn "    systemctl --user daemon-reload"
  fi
fi

log "memory layer ensured: zram + ${SWAP_TARGET_GB} GB swapfile, reclaim tuned,"
log "  app.slice throttled at 12G, gnome-shell exempt from systemd-oomd"
log "  check it with:  swapon --show ; zramctl ; oomctl"
