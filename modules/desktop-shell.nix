# Windows-style single bottom taskbar for the GNOME session, plus a tidied
# "Show Apps" grid (default apps grouped into folders — see the App grid
# organisation block below).
#
# Stock Ubuntu splits the desktop furniture in two: Ubuntu Dock down the left
# edge and gnome-shell's own top bar holding the clock, tray and system menu.
# This module replaces both with one bar along the bottom — Dash to Panel folds
# the top bar's contents into the same panel as the app buttons, which is the
# only way to get everything onto a single edge (the top bar is part of
# gnome-shell itself, not an extension, so it cannot simply be moved).
#
# Layout, left to right: the Ubuntu "show applications" button, the app buttons
# centred on the monitor, then the clock, tray icons and system/power menu at
# the right.
#
# ── Notes for a future compositor swap ──────────────────────────────────────
# Everything here is GNOME-specific: a gnome-shell extension plus dconf keys.
# It is deliberately one self-contained module gated on a single option, so a
# move to another shell (Hyprland, etc.) means turning this off rather than
# unpicking settings scattered across the config. Nothing else depends on it.
#
# ── Two things that will bite if you touch this ─────────────────────────────
# 1. The extension MUST be in home.packages, not merely symlinked into
#    ~/.local/share. The symlink points into /nix/store, and without a profile
#    reference nothing holds a GC root — `nix-collect-garbage` would delete the
#    extension and leave a dangling link, i.e. no taskbar at the next login.
# 2. gnome-shell only scans for extensions at startup, and under Wayland the
#    shell cannot be restarted without ending the session. Installing or
#    enabling this therefore takes effect at the NEXT LOGIN, not on switch.
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.desktopShell;

  uuid = "dash-to-panel@jderose9.github.com";
  dashToPanel = pkgs.gnomeExtensions.dash-to-panel;

  # Panel contents. "stackedTL" = packed to the left on a bottom panel,
  # "stackedBR" = packed to the right, "centerMonitor" = centred on the screen
  # (rather than centred in the leftover space, which drifts as apps open).
  elements = [
    { element = "showAppsButton";   visible = true;  position = "stackedTL"; }
    # Activities is redundant once there is a real taskbar, and it is the one
    # element that makes the bar stop looking like Windows.
    { element = "activitiesButton"; visible = false; position = "stackedTL"; }
    { element = "leftBox";          visible = true;  position = "stackedTL"; }
    { element = "taskbar";          visible = true;  position = "centerMonitor"; }
    { element = "centerBox";        visible = true;  position = "stackedBR"; }
    { element = "rightBox";         visible = true;  position = "stackedBR"; }
    { element = "dateMenu";         visible = true;  position = "stackedBR"; }
    { element = "systemMenu";       visible = true;  position = "stackedBR"; }
    { element = "desktopButton";    visible = false; position = "stackedBR"; }
  ];

  # Both built-in panels get the same treatment, so the bar looks right
  # whichever screen is primary and whether or not the second one is lit.
  perMonitor = value: builtins.toJSON { "0" = value; "1" = value; };

  # ── App grid organisation ("Show Apps") ─────────────────────────────────────
  # Tidies the grid so a fresh install is not a flat wall of system tools: the
  # default/system apps are grouped into folders; the apps you actually launch
  # sit at the top level. Every app NOT named below — i.e. anything installed
  # later — is left out of the folders and off the layout, so GNOME appends it
  # to the END of the grid, where you will notice it and can decide where it
  # goes. File it by adding it to a folder (or to `topLevel`) here and re-running
  # `make home`; until then it waits at the end.
  #
  # This is declarative and re-asserted on every switch, so the grid is
  # reproducible — but a drag-rearrange in GNOME does NOT survive a `make home`.
  # Organise here, in the repo, not by dragging.
  #
  # Folders use explicit `apps` lists rather than `categories` on purpose: a
  # category folder would swallow matching new apps automatically, which is the
  # opposite of "new apps wait at the end for me to sort".
  appFolders = [
    { id = "updaters"; name = "Updaters"; apps = [
        "update-manager.desktop"
        "firmware-updater_firmware-updater.desktop"
        "software-properties-gtk.desktop"
        "software-properties-drivers.desktop"
        "snap-store_snap-store.desktop"
      ]; }
    { id = "monitoring"; name = "Monitoring"; apps = [
        "org.gnome.SystemMonitor.desktop"
        "gnome-system-monitor-kde.desktop"
        "org.gnome.PowerStats.desktop"
        "org.gnome.baobab.desktop"
        "org.gnome.Logs.desktop"
        "bottom.desktop"
        "htop.desktop"
      ]; }
    { id = "system"; name = "System"; apps = [
        "org.gnome.DiskUtility.desktop"
        "timeshift-gtk.desktop"
        "gnome-session-properties.desktop"
        "org.gnome.seahorse.Application.desktop"
      ]; }
    { id = "settings"; name = "Settings"; apps = [
        "nm-connection-editor.desktop"
        "gnome-language-selector.desktop"
        "org.freedesktop.IBus.Setup.desktop"
        "im-config.desktop"
      ]; }
    { id = "utilities"; name = "Utilities"; apps = [
        "org.gnome.Characters.desktop"
        "org.gnome.font-viewer.desktop"
        "yelp.desktop"
        "org.gnome.Evince.desktop"
        "org.gnome.eog.desktop"
        "org.gnome.clocks.desktop"
        "info.desktop"
        "org.gnome.Terminal.desktop"
        "vim.desktop"
        "gvim.desktop"
      ]; }
  ];

  # Top-level grid order: the apps you launch, then the folders. Newly-installed
  # apps are deliberately absent, so GNOME appends them after all of this.
  topLevel = [
    "brave-browser.desktop"
    "discord.desktop"
    "notion.desktop"
    "joplin.desktop"
    "thunderbird.desktop"
    "youtube-music.desktop"
    "com.anthropic.Claude.desktop"
    "com.mitchellh.ghostty.desktop"
    "code.desktop"
    "bruno.desktop"
    "drawio.desktop"
    "com.obsproject.Studio.desktop"
    "LocalSend.desktop"
    "open-whispr.desktop"
    "Zoom.desktop"
    "curseforge.desktop"
    "warthunder-launcher.desktop"
    "org.gnome.Nautilus.desktop"
    "org.gnome.Settings.desktop"
    "org.gnome.Calculator.desktop"
    "org.gnome.TextEditor.desktop"
  ] ++ map (f: f.id) appFolders;

  # Build the app-picker-layout GVariant by hand (its type is aa{sv} — an array
  # of pages, each a dict of item -> {'position': <n>}). One page is enough;
  # GNOME repaginates for display. Anything not positioned here lands after the
  # last position, i.e. at the end of the grid.
  gv = lib.hm.gvariant;
  svType = gv.type.dictionaryEntryOf [ gv.type.string gv.type.variant ];   # {sv}
  positionOf = n: gv.mkVariant (gv.mkArray svType [
    (gv.mkDictionaryEntry [ "position" (gv.mkVariant (gv.mkInt32 n)) ])
  ]);
  appPickerPage = gv.mkArray svType
    (lib.imap0 (i: id: gv.mkDictionaryEntry [ id (positionOf i) ]) topLevel);
  appPickerLayout = gv.mkArray (gv.type.arrayOf svType) [ appPickerPage ];

  # One dconf path per folder: /org/gnome/desktop/app-folders/folders/<id>.
  folderSettings = lib.listToAttrs (map (f: {
    name = "org/gnome/desktop/app-folders/folders/${f.id}";
    value = { name = f.name; translate = false; apps = f.apps; };
  }) appFolders);
in
{
  options.modules.desktopShell.enable = lib.mkEnableOption ''
    a single Windows-style taskbar along the bottom of the screen: Dash to Panel
    replaces Ubuntu Dock and folds gnome-shell's top bar (clock, tray, system
    menu) into the same panel. Also organises the "Show Apps" grid into folders.
    Takes effect at the next login — gnome-shell only picks up extensions at
    startup, and Wayland cannot restart it in place
  '';

  config = lib.mkIf cfg.enable {
    # Also the GC root for the symlink below — see the header.
    home.packages = [ dashToPanel ];

    xdg.dataFile."gnome-shell/extensions/${uuid}".source =
      "${dashToPanel}/share/gnome-shell/extensions/${uuid}";

    dconf.settings = {
      # Ubuntu Dock and Dash to Panel both own the dash; running both gives two
      # docks, so the stock one is explicitly disabled rather than just dropped
      # from the enabled list (Ubuntu's session re-enables it otherwise).
      #
      # Note this pins the whole enabled list: an extension you turn on later in
      # the Extensions app is switched back off at the next `make home`. Add it
      # here instead — that is the trade for the set being reproducible.
      "org/gnome/shell" = {
        enabled-extensions = [ "ding@rastersoft.com" "tiling-assistant@ubuntu.com" uuid ];
        disabled-extensions = [ "ubuntu-dock@ubuntu.com" ];
        # App grid order — see appFolders/topLevel above. New apps append at end.
        app-picker-layout = appPickerLayout;
      };

      "org/gnome/shell/extensions/dash-to-panel" = {
        panel-positions = perMonitor "BOTTOM";
        panel-sizes = perMonitor 40;          # 48 is the default; 40 fits more in
        panel-element-positions = perMonitor elements;
        appicon-padding = 4;
        # Space around each app icon. Dash to Panel's default of 8 is too wide a
        # gap and 0 packs them too tight; 2 is a hair of breathing room
        # (appicon-padding also keeps the clickable area larger than the icon).
        appicon-margin = 2;
        # false = do not keep gnome-shell's top bar. This is what actually
        # merges the clock/tray/system menu into the bottom panel.
        stockgs-keep-top-panel = false;
      };

      # Only consulted if Ubuntu Dock is ever turned back on, but it keeps the
      # "dash lives at the bottom" intent true in that fallback too.
      "org/gnome/shell/extensions/dash-to-dock".dock-position = "BOTTOM";

      # The folder set. Replaces Ubuntu's stock children (Utilities/YaST/Pardus)
      # with ours; the per-folder name/apps live in folderSettings, merged below.
      "org/gnome/desktop/app-folders".folder-children = map (f: f.id) appFolders;
    } // folderSettings;
  };
}
