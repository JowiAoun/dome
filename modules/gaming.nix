{ config, lib, pkgs, ... }:

# Gaming (modules.gaming) — the user half of the gameMode switch. The other
# half is system/86-gamemode.sh, which writes /etc/gamemode.ini; both read
# `gameMode` in user-config.nix.
#
# All this module does is make the game actually ASK for gamemode. GameMode is
# opt-in per process: the daemon does nothing until a client calls into it, and
# nothing on this machine calls into it, so an installed-but-unwired gamemode
# (which is what Ubuntu leaves you with) never runs.
#
# The wiring is /usr/games/gamemoderun, which is a three-line script that sets
# LD_PRELOAD=libgamemodeauto.so.0 and execs its argument. That library's
# constructor makes the D-Bus request, and LD_PRELOAD is inherited, so wrapping
# the CurseForge launcher reaches the JVM it spawns — which is the process we
# actually want registered. (system/86-gamemode.sh's whitelist is what keeps the
# Electron launcher itself from counting; see its header.)
#
# Why this edits the launcher at activation instead of declaring it.
#
# CurseForge comes from a .deb, so /usr/share/applications/curseforge.desktop
# belongs to the package and Nix cannot rewrite it. The established answer in
# this repo is an override in XDG_DATA_HOME, which wins because the desktop spec
# searches XDG_DATA_HOME before XDG_DATA_DIRS — and modules/apps.nix ALREADY
# writes that override, to append modules.apps.chromiumFlags to the Exec of
# apt-installed Electron apps.
#
# So there is exactly one file and two modules with an opinion about its Exec
# line. Declaring it here as well does not work: apps.nix writes a real file
# from an activation script, which silently overwrites the symlink an
# `xdg.dataFile` would have placed there — the last writer wins, gamemode loses,
# and nothing reports a conflict because there is no Nix-level conflict to
# report. (It also leaves home-manager with an unmanaged file where it expects
# its own symlink, which fails the NEXT switch on a backup collision.)
#
# Composing is the fix: run after apps.nix's entry and prepend the wrapper to
# whatever Exec it produced. Both features survive, apps.nix needs no knowledge
# of gaming.nix, and turning gameMode off is self-healing — apps.nix rewrites the
# entry from the package's own on every switch, so the prefix simply stops being
# re-applied.
let
  cfg = config.modules.gaming;

  curseforgeBin = "/opt/CurseForge/curseforge";
  gamemoderun = "/usr/games/gamemoderun";
in
{
  options.modules.gaming.enable = lib.mkEnableOption ''
    game launchers wired to Feral GameMode. Starts the CurseForge launcher
    through gamemoderun, so Minecraft's JVM registers with the daemon and gets
    the performance CPU governor for as long as it runs. Pairs with
    system/86-gamemode.sh, which writes /etc/gamemode.ini — enable both with
    `gameMode = true;` in user-config.nix
  '';

  config = lib.mkIf cfg.enable {
    # entryAfter appsDesktopIntegration, not linkGeneration: that is the entry in
    # modules/apps.nix that writes the override this one amends. Ordering after
    # it is the whole point — see the header.
    home.activation.gamemodeLaunchers =
      lib.hm.dag.entryAfter [ "appsDesktopIntegration" ] ''
        _cf_entry="${config.xdg.dataHome}/applications/curseforge.desktop"
        _cf_system=/usr/share/applications/curseforge.desktop

        if [ ! -x ${gamemoderun} ]; then
          echo "[gaming] ${gamemoderun} is missing — run 'sudo make system' to install gamemode"
        elif [ ! -x ${curseforgeBin} ]; then
          echo "[gaming] CurseForge is not installed — nothing to wrap"
        else
          # apps.nix normally put the override there already. If modules.apps is
          # off it did not, so seed one from the package's own entry.
          if [ ! -e "$_cf_entry" ] && [ -e "$_cf_system" ]; then
            run mkdir -p "$(dirname "$_cf_entry")"
            run cp "$_cf_system" "$_cf_entry"
            run chmod u+w "$_cf_entry"
          fi

          # Idempotent: prepend only when the wrapper is not already the Exec.
          # Everything after Exec= is preserved, which is what keeps apps.nix's
          # chromiumFlags on the line.
          if [ -e "$_cf_entry" ] && ! grep -q "^Exec=${gamemoderun} " "$_cf_entry"; then
            run sed -i -E 's|^Exec=|Exec=${gamemoderun} |' "$_cf_entry"
            echo "[gaming] CurseForge now launches through gamemoderun"
          fi
        fi
      '';
  };
}
