# Windows-style single bottom taskbar for the GNOME session.
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
in
{
  options.modules.desktopShell.enable = lib.mkEnableOption ''
    a single Windows-style taskbar along the bottom of the screen: Dash to Panel
    replaces Ubuntu Dock and folds gnome-shell's top bar (clock, tray, system
    menu) into the same panel. Takes effect at the next login — gnome-shell only
    picks up extensions at startup, and Wayland cannot restart it in place
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
      };

      "org/gnome/shell/extensions/dash-to-panel" = {
        panel-positions = perMonitor "BOTTOM";
        panel-sizes = perMonitor 40;          # 48 is the default; 40 fits more in
        panel-element-positions = perMonitor elements;
        appicon-padding = 4;
        # Space around each app icon. Dash to Panel's default is 8, which reads
        # as too much gap between icons; 0 packs them tight (appicon-padding
        # still keeps the clickable area a little larger than the icon itself).
        appicon-margin = 0;
        # false = do not keep gnome-shell's top bar. This is what actually
        # merges the clock/tray/system menu into the bottom panel.
        stockgs-keep-top-panel = false;
      };

      # Only consulted if Ubuntu Dock is ever turned back on, but it keeps the
      # "dash lives at the bottom" intent true in that fallback too.
      "org/gnome/shell/extensions/dash-to-dock".dock-position = "BOTTOM";
    };
  };
}
