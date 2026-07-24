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
# Why a shadowing .desktop entry rather than mkdesktop: CurseForge comes from a
# .deb and already ships /usr/share/applications/curseforge.desktop, so it is
# not the hand-installed-binary case CLAUDE.md points mkdesktop at. An entry
# with the same id in ~/.local/share/applications takes precedence over the
# system one (XDG_DATA_HOME is searched before XDG_DATA_DIRS), so this replaces
# the launcher without touching the package — and keeps working across
# CurseForge updates, which cannot clobber a file in $HOME.
let
  cfg = config.modules.gaming;

  curseforgeBin = "/opt/CurseForge/curseforge";
  gamemoderun = "/usr/games/gamemoderun";

  # Every field except Exec is copied verbatim from the shipped entry.
  #
  # StartupWMClass is the one that cannot be guessed (CLAUDE.md): it is the
  # class the running window reports, and dropping it makes the dash show a
  # generic placeholder instead of CurseForge's own icon.
  #
  # TryExec points at CurseForge, NOT at the wrapper: the desktop spec hides an
  # entry whose TryExec is missing, so uninstalling CurseForge makes this
  # launcher disappear on its own rather than leaving a dead tile in the grid.
  #
  # The id stays curseforge.desktop, so the grid placement in
  # modules/desktop-shell.nix's `topLevel` keeps pointing at it.
  curseforgeEntry = pkgs.writeTextDir "share/applications/curseforge.desktop" ''
    [Desktop Entry]
    Name=CurseForge
    Comment=The CurseForge Electron App
    Exec=${gamemoderun} ${curseforgeBin} %U
    TryExec=${curseforgeBin}
    Icon=curseforge
    Type=Application
    Terminal=false
    StartupWMClass=CurseForge
    MimeType=x-scheme-handler/curseforge;x-scheme-handler/cfauth;x-scheme-handler/curseforge-checkout;
    Categories=Game;
  '';
in
{
  options.modules.gaming.enable = lib.mkEnableOption ''
    game launchers wired to Feral GameMode. Replaces the CurseForge launcher
    with one that starts through gamemoderun, so Minecraft's JVM registers with
    the daemon and gets the performance CPU governor for as long as it runs.
    Pairs with system/86-gamemode.sh, which writes /etc/gamemode.ini — enable
    both with `gameMode = true;` in user-config.nix
  '';

  config = lib.mkIf cfg.enable {
    xdg.dataFile."applications/curseforge.desktop".source =
      "${curseforgeEntry}/share/applications/curseforge.desktop";
  };
}
