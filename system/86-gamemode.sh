#!/usr/bin/env bash
# 86-gamemode.sh — Feral GameMode's configuration, so the CPU governor moves
# while a game is running.
#
# GameMode is a daemon a game asks, over D-Bus, to make the machine fast: CPU
# governor to performance, screensaver inhibited, and back to normal when the
# game exits. Ubuntu's gamemode package installs the daemon and the client
# library but ships NO /etc/gamemode.ini, so every setting is a compiled-in
# default — including the ones that are wrong for this hardware.
#
# The two settings that matter here, and why:
#
#   igpu_desiredgov / igpu_power_threshold
#     This machine has no discrete GPU: the Core Ultra 7 155H's Arc graphics
#     share one power budget with the CPU cores. Pinning the governor to
#     performance therefore does not just cost battery — it takes watts away
#     from the GPU that is the actual bottleneck in a game, and can be a net
#     LOSS of frames. GameMode has explicit logic for this: once GPU power draw
#     passes igpu_power_threshold of the CPU's, it uses igpu_desiredgov instead
#     of desiredgov. Both are spelled out below rather than left implicit,
#     because on an iGPU laptop this is the whole reason the config exists.
#
#   [filter] whitelist
#     /usr/games/gamemoderun works by setting LD_PRELOAD=libgamemodeauto.so.0,
#     which every CHILD process inherits. modules/gaming.nix wraps CurseForge in
#     it, so both the Electron launcher and the game's JVM ask for gamemode —
#     and the launcher asking would hold the governor at performance for as long
#     as the modpack browser is open, which may be all day. Whitelisting `java`
#     means the governor moves when Minecraft starts and not before.
#     Add a game by adding its binary name here (War Thunder would be `aces`).
#
# Why the root layer: /etc/gamemode.ini is system state. The other half of this
# feature — the launcher that actually invokes gamemoderun — is a user-level
# .desktop entry and lives in modules/gaming.nix, where home-manager owns it.
# Both halves read the same `gameMode` switch in user-config.nix.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

CONF=/etc/gamemode.ini

# user-config.nix is the source of truth; GAME_MODE=1/0 overrides it for a
# single run (run.sh sets it after sudo has already dropped privileges, so it
# survives sudo's env_reset).
want=0
if config_flag gameMode; then want=1; fi
case "${GAME_MODE:-}" in
  1) want=1 ;;
  0) want=0 ;;
esac

# ── off: remove what we wrote, leave everything else alone ───────────────────
if [ "$want" != 1 ]; then
  # grep reads the file directly rather than `head -n1 | grep -q`: lib.sh sets
  # pipefail, and `grep -q` exiting early can SIGPIPE the writer, which would
  # make a file dome DID write look like one it did not.
  if [ -f "$CONF" ] && grep -q 'Managed by dome' "$CONF"; then
    log "gameMode is off — removing $CONF"
    if [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would remove $CONF"
    else
      rm -f "$CONF"
    fi
    mark_change
    log "gamemode falls back to its compiled-in defaults"
  else
    log "gameMode is not enabled in user-config.nix — skipping gamemode config"
  fi
  exit 0
fi

ensure_pkg gamemode

read -r -d '' CONF_BODY <<'EOF' || true
# Managed by dome (system/86-gamemode.sh) — regenerated on every run.
# Turn it off with `gameMode = false;` in user-config.nix, which REMOVES this
# file and hands the settings back to gamemode's built-in defaults.

[general]
# Keep the screen from blanking mid-game.
inhibit_screensaver=1

# The governor while a game runs and the discrete GPU is doing the work.
desiredgov=performance

# ...and the governor when the INTEGRATED GPU is the bottleneck, which on this
# machine is always: CPU and Arc graphics share one power budget, so holding the
# cores at performance starves the GPU. gamemode switches to this once GPU power
# draw exceeds igpu_power_threshold (0.3 = 30%) of the CPU's.
igpu_desiredgov=powersave
igpu_power_threshold=0.3

# SCHED_ISO would need a kernel patch that mainline never took; leaving it on
# just produces a warning in the daemon log on every launch.
softrealtime=off

[filter]
# Only these binaries may put the machine into game mode. See the header: the
# LD_PRELOAD that gamemoderun sets is inherited by children, so without this the
# CurseForge launcher itself would count as a game.
whitelist=java
EOF

if [ -f "$CONF" ] && [ "$(cat "$CONF")" = "$CONF_BODY" ]; then
  log "gamemode config up to date: $CONF"
elif [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would write $CONF"
  mark_change
else
  log "writing $CONF"
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # expand tmp now so the trap knows the path
  trap "rm -f '$tmp'" EXIT
  printf '%s\n' "$CONF_BODY" > "$tmp"
  install -o root -g root -m 0644 "$tmp" "$CONF"
  mark_change
fi

# The daemon is a user service and D-Bus-activated, so there is nothing to
# enable: it starts when a game asks for it and exits again afterwards. It does
# re-read /etc/gamemode.ini at startup, so a config change lands on the next
# launch with no restart needed.
log "gamemode configured — games launched through gamemoderun get the performance governor"
log "  the CurseForge launcher wired to it comes from modules/gaming.nix (make home)"
log "  check it while a game runs with:  gamemodelist"
