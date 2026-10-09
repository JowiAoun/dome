{ config, lib, pkgs, ... }:

# Vinegar (modules.vinegar) — a MANUAL command to clear Roblox/Wine sessions
# that outlived the game.
#
# ── Read this before making it automatic again ───────────────────────────────
#
# An earlier version of this module ran on a systemd timer and killed the
# machine's graphical session twice in one day. Both times it stopped a Roblox
# session that was actively being played, and mutter segfaulted ~400 ms later
# when the client vanished with live Wayland surfaces:
#
#   20:43:16.329  Stopping app-flatpak-org.vinegarhq.Sober-685963.scope...
#   20:43:16.731  GNOME Shell crashed with signal 11
#
# Three separate mistakes, each worth keeping in mind:
#
#   1. THE GLOB WAS TOO WIDE. It matched `app-flatpak-org.vinegarhq.*.scope`.
#      The vendor ships TWO apps: org.vinegarhq.Vinegar (Roblox under Wine) and
#      org.vinegarhq.Sober (Roblox as a NATIVE Linux binary). The leak only
#      ever came from Vinegar; the timer reaped Sober.
#
#   2. THE LIVENESS TEST WAS WINE-SPECIFIC. It looked for RobloxPlayerBeta.exe
#      or RobloxStudioBeta.exe in each process's command line. Sober has no
#      such process, so a perfectly healthy game read as "no game process".
#
#   3. IT FAILED DANGEROUS. "I do not recognise anything in here" meant KILL.
#      For anything that ends a user's session it has to mean LEAVE ALONE.
#
# And the reason (2) could not simply be patched: **a Flatpak sandbox cannot be
# introspected per-process from outside it.** Measured on a live Sober session:
#
#   /proc/<pid>/fd       -> Permission denied     (so no "does it hold a DRM fd")
#   /proc/<pid>/cmdline  -> "/proc/self/exe --"   (so no matching on a binary name)
#
# Only the CGROUP is readable, because it belongs to our own user manager:
#
#   memory.current -> 2062 MB
#   cpu.stat       -> usage_usec advancing 8.3 s per 3 s of wall clock
#
# So the only trustworthy signal is "is this cgroup doing any work", and that
# is a heuristic, not a fact: a paused or minimised game can go quiet too.
#
# ── Why this is a command and not a timer ────────────────────────────────────
#
# The leak is worth about 30 MB of RSS and 150 MB of swap across two stranded
# scopes — real, but small. It was never the interesting number; the same
# investigation found a stranded Mission Control GPU process holding a
# gigabyte, and 8.5 GB of the machine paged out. Weighing ~180 MB against
# "ends the session and every unsaved thing in it", automation is not worth it.
#
# So: no timer, no unit, no background anything. `vinegar-reap` prints what it
# would stop and exits; `vinegar-reap --stop` actually stops it. Run it when
# you know you are not playing. The human is the reliable liveness check.

let
  cfg = config.modules.vinegar;

  reaper = pkgs.writeShellScriptBin "vinegar-reap" ''
    set -uo pipefail

    grace=${toString cfg.graceSeconds}
    sample=3
    # A live Roblox burns whole seconds of CPU per second of wall clock; idle
    # Wine plumbing burns effectively none. 250 ms over a 3 s window sits three
    # orders of magnitude below "playing" and comfortably above "nothing".
    idle_usec=250000
    do_stop=0

    for a in "$@"; do
      case "$a" in
        --stop) do_stop=1 ;;
        -h|--help)
          echo "usage: vinegar-reap [--stop]"
          echo "  Lists leftover ${cfg.appId} scopes with no sign of a running game."
          echo "  Default is a dry run; --stop actually stops them."
          echo "  Sober (org.vinegarhq.Sober) is deliberately NEVER touched."
          exit 0 ;;
        *) echo "vinegar-reap: unknown argument '$a'" >&2; exit 2 ;;
      esac
    done

    # Scoped to ONE app id on purpose — see mistake (1) in the header. Widening
    # this is what killed the session; do not widen it.
    units="$(${pkgs.systemd}/bin/systemctl --user list-units --type=scope \
               --plain --no-legend --all \
               'app-flatpak-${cfg.appId}-*.scope' 2>/dev/null || true)"
    if [ -z "$units" ]; then
      echo "no ${cfg.appId} scopes"
      exit 0
    fi

    now_s="$(${pkgs.coreutils}/bin/date +%s)"
    found=0

    while read -r unit _rest; do
      [ -n "$unit" ] || continue

      state="$(${pkgs.systemd}/bin/systemctl --user show "$unit" \
                 -p ActiveState --value 2>/dev/null || true)"
      [ "$state" = active ] || continue

      # Wall clock on BOTH sides. /proc/uptime is CLOCK_BOOTTIME and counts
      # suspended time; systemd's *TimestampMonotonic is CLOCK_MONOTONIC and
      # does not. Subtracting one from the other adds every second this laptop
      # ever spent in s2idle — 24 h of it, measured — so a scope created two
      # seconds ago reads as a day old. See CLAUDE.md.
      started="$(${pkgs.systemd}/bin/systemctl --user show "$unit" \
                   -p ActiveEnterTimestamp --value 2>/dev/null || true)"
      [ -n "$started" ] || continue
      start_s="$(${pkgs.coreutils}/bin/date -d "$started" +%s 2>/dev/null || true)"
      case "$start_s" in ""|*[!0-9]*) continue ;; esac
      age=$(( now_s - start_s ))

      cgroup="$(${pkgs.systemd}/bin/systemctl --user show "$unit" \
                  -p ControlGroup --value 2>/dev/null || true)"
      [ -n "$cgroup" ] || continue
      cpustat="/sys/fs/cgroup''${cgroup}/cpu.stat"
      memcur="/sys/fs/cgroup''${cgroup}/memory.current"
      [ -r "$cpustat" ] || continue

      read_usage() {
        ${pkgs.gawk}/bin/awk '/^usage_usec/ { print $2 }' "$1" 2>/dev/null
      }
      u1="$(read_usage "$cpustat")"
      ${pkgs.coreutils}/bin/sleep "$sample"
      u2="$(read_usage "$cpustat")"
      case "''${u1:-}''${u2:-}" in ""|*[!0-9]*) continue ;; esac
      delta=$(( u2 - u1 ))

      mem=0
      [ -r "$memcur" ] && mem="$(${pkgs.coreutils}/bin/cat "$memcur" 2>/dev/null || echo 0)"
      mem_mb=$(( mem / 1048576 ))

      busy="idle"
      [ "$delta" -ge "$idle_usec" ] && busy="BUSY"

      printf '%s\n  age %ss, %s MB, %s ms CPU in %ss -> %s\n' \
        "$unit" "$age" "$mem_mb" "$(( delta / 1000 ))" "$sample" "$busy"

      if [ "$busy" = BUSY ]; then
        echo "  keeping: still doing work"
        continue
      fi
      if [ "$age" -lt "$grace" ]; then
        echo "  keeping: younger than the ''${grace}s grace period"
        continue
      fi

      found=1
      if [ "$do_stop" = 1 ]; then
        echo "  stopping"
        ${pkgs.systemd}/bin/systemctl --user stop "$unit" 2>/dev/null || true
      else
        echo "  WOULD stop (re-run with --stop)"
      fi
    done <<<"$units"

    if [ "$do_stop" = 1 ]; then
      ${pkgs.systemd}/bin/systemctl --user reset-failed \
        'app-flatpak-${cfg.appId}-*.scope' 2>/dev/null || true
    fi
    [ "$found" = 1 ] || echo "nothing to reap"
  '';
in
{
  options.modules.vinegar = {
    enable = lib.mkEnableOption ''
      the `vinegar-reap` command, which clears Vinegar/Wine Flatpak scopes left
      running after Roblox exits. Installs a command only — no timer, no
      service, nothing in the background. See the header of modules/vinegar.nix
      for why this is deliberately manual
    '';

    appId = lib.mkOption {
      type = lib.types.str;
      default = "org.vinegarhq.Vinegar";
      description = ''
        The single Flatpak app id whose scopes may be reaped. Deliberately not
        a glob: the vendor also ships org.vinegarhq.Sober, a NATIVE Roblox
        client that does not leak and must never be stopped by this.
      '';
    };

    graceSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Minimum age before a quiet scope is offered for reaping. Generous on
        purpose — it costs nothing to wait, and a first launch or a Roblox
        update can sit in wineboot for a long time.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ reaper ];
  };
}
