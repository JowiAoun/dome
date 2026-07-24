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

  # Puts dash-pinned apps back into the "Show Apps" grid. GNOME 40+ deliberately
  # hides every favourite from the grid so it is not shown in two places; that is
  # stock behaviour with no setting to toggle it. This extension undoes it, so
  # ALL installed apps appear in the grid, the dash ones included — which is the
  # whole reason the app-picker-layout above bothers to position them. Works on
  # GNOME 46 (its metadata lists shell-version 45-49).
  pinnedInGridUuid = "pinned-apps-in-appgrid@brunosilva.io";
  pinnedInGrid = pkgs.gnomeExtensions.keep-pinned-apps-in-appgrid;

  # The one extension here that Nix does NOT install. It has to live in
  # /usr/share/gnome-shell/extensions to be visible to the GDM greeter, which
  # runs as the gdm user and cannot read anything under /home — so
  # system/87-login-pin.sh installs it and this module only switches it on for
  # the lock screen. Listing a uuid that is not installed is harmless: the shell
  # logs that it cannot find it and carries on.
  pinUnlockUuid = "pin-unlock@dome.local";

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
    { id = "development"; name = "Development"; apps = [
        "bruno.desktop"
        "code.desktop"
      ]; }
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
        "org.gnome.Settings.desktop"
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
        # Easy Effects (audio EQ/effects) has no better home than the general
        # utilities bucket among these folders.
        "com.github.wwmm.easyeffects.desktop"
        "info.desktop"
        "org.gnome.Terminal.desktop"
        "vim.desktop"
        "gvim.desktop"
      ]; }
  ];

  # Top-level grid order: folders FIRST (you asked for folders up top), then the
  # apps you launch. Newly-installed apps are deliberately absent, so GNOME
  # appends them after all of this — at the end of the grid.
  topLevel = map (f: f.id) appFolders ++ [
    "brave-browser.desktop"
    "discord.desktop"
    "notion.desktop"
    "joplin.desktop"
    "thunderbird.desktop"
    "youtube-music.desktop"
    "com.anthropic.Claude.desktop"
    "com.mitchellh.ghostty.desktop"
    "drawio.desktop"
    "com.obsproject.Studio.desktop"
    "LocalSend.desktop"
    "open-whispr.desktop"
    "Zoom.desktop"
    "curseforge.desktop"
    "warthunder-launcher.desktop"
    "org.gnome.Nautilus.desktop"
    "org.gnome.Calculator.desktop"
    "org.gnome.TextEditor.desktop"
  ];

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

  options.modules.desktopShell.loginPinUnlock = lib.mkEnableOption ''
    the pin-unlock extension on the LOCK screen, so a PIN of the configured
    length unlocks without pressing Enter.

    The login screen half is not here and cannot be: that is a separate
    gnome-shell running as the gdm user, enabled from its own dconf database by
    system/87-login-pin.sh. This only adds the uuid to enabled-extensions, which
    is the authoritative list — without it the extension would be switched back
    off on the next `make home`.

    Wired from `loginPinLength` in user-config.nix, the same value the system
    script writes for the extension to read
  '';

  config = lib.mkIf cfg.enable {
    # Also the GC root for the symlinks below — see the header.
    home.packages = [ dashToPanel pinnedInGrid ];

    xdg.dataFile."gnome-shell/extensions/${uuid}".source =
      "${dashToPanel}/share/gnome-shell/extensions/${uuid}";
    xdg.dataFile."gnome-shell/extensions/${pinnedInGridUuid}".source =
      "${pinnedInGrid}/share/gnome-shell/extensions/${pinnedInGridUuid}";

    dconf.settings = {
      # 12-hour clock (AM/PM) instead of GNOME's 24h default; affects both the
      # top-bar clock and the Dash to Panel clock, which reads this same key.
      "org/gnome/desktop/interface".clock-format = "12h";

      # Middle click must never paste. This is the GTK-wide half of that (the
      # Chromium/Electron half is modules.apps.chromiumFlags, the Gecko half is
      # the autoconfig in modules/apps.nix) and it covers every GTK3/GTK4 text
      # widget on the machine: Nautilus, Text Editor, Settings, the GTK chrome
      # of Firefox and Thunderbird, GTK file dialogs everywhere.
      #
      # Set explicitly rather than trusted, because the default is NOT the same
      # everywhere and `gsettings get` in a Nix shell lies about it: nixpkgs'
      # gsettings-desktop-schemas defaults this to false, Ubuntu's
      # /usr/share/glib-2.0/schemas defaults it to TRUE, and which one an app
      # sees depends on the XDG_DATA_DIRS it was launched with. An app started
      # from the GNOME shell resolves Ubuntu's copy and pastes. A dconf value
      # outranks every schema default, so this is the only way to make the
      # answer the same for all of them.
      "org/gnome/desktop/interface".gtk-enable-primary-paste = false;

      # Ubuntu Dock and Dash to Panel both own the dash; running both gives two
      # docks, so the stock one is explicitly disabled rather than just dropped
      # from the enabled list (Ubuntu's session re-enables it otherwise).
      #
      # Note this pins the whole enabled list: an extension you turn on later in
      # the Extensions app is switched back off at the next `make home`. Add it
      # here instead — that is the trade for the set being reproducible.
      "org/gnome/shell" = {
        enabled-extensions = [ "ding@rastersoft.com" "tiling-assistant@ubuntu.com" uuid pinnedInGridUuid ]
          ++ lib.optional cfg.loginPinUnlock pinUnlockUuid;
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

      # Keep the file indexer out of the game directories.
      #
      # Tracker recursively indexes the XDG dirs, and ~/Documents is one of them
      # — which is where CurseForge puts its Minecraft root by default (2.3 GB
      # of instances, libraries and assets here). Nothing in a modpack is worth
      # finding in GNOME search, and every modpack update rewrites hundreds of
      # files, so leaving it in scope means a reindex sweep starting during the
      # session you least want the CPU and disk taken.
      #
      # Absolute paths, not the bare directory name Tracker also accepts: a
      # basename rule would silently swallow any directory called "curseforge"
      # anywhere in the indexed tree.
      #
      # Note this pins the whole list, like enabled-extensions above — the four
      # entries below the game paths are the schema defaults, repeated because a
      # dconf write replaces rather than extends. Check them against
      # `gsettings get org.freedesktop.Tracker3.Miner.Files ignored-directories`
      # if a future Tracker changes them.
      #
      # The path is NOT the schema id lowercased-with-slashes, which is the
      # obvious guess and is wrong. The id is org.freedesktop.Tracker3.Miner.Files
      # but the schema declares path="/org/freedesktop/tracker/miner/files/" — no
      # "3", all lower case. dconf.settings writes wherever it is told and never
      # validates against a schema, so the wrong path stores a value that simply
      # nothing reads: `gsettings get` keeps returning the default and it looks
      # like the setting was ignored. Confirmed against the shipped schema:
      #
      #   grep -o 'id="org.freedesktop.Tracker3.Miner.Files" path="[^"]*"' \
      #     /usr/share/glib-2.0/schemas/*.xml
      #
      # Worth doing for any non-org/gnome schema before trusting the path.
      "org/freedesktop/tracker/miner/files".ignored-directories = [
        "${config.home.homeDirectory}/Documents/curseforge"
        "${config.home.homeDirectory}/Games"
        "po"
        "CVS"
        "core-dumps"
        "lost+found"
      ];
    } // folderSettings;
  };
}
