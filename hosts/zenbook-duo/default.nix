# Host profile: the ASUS Zenbook Duo (2024) UX8406MA running Ubuntu 24.04.
# Pairs with the system layer: sudo make system HOST=zenbook-duo
#
# Nothing Duo-specific lives in this repo. The hardware support comes from
# github.com/JowiAoun/linux-on-zenbook-duo (flake input `zenbook-duo`), whose
# home-manager module generates the duo-* user units, the config file and the
# EasyEffects speaker chain; system/40-zenbook-duo.sh runs that repo's root
# installer (udev, sudoers, the helper, the touchpad quirk, GRUB).
{ config, inputs, ... }:

{
  imports = [ inputs.zenbook-duo.homeManagerModules.default ];

  # Nix-installed GUI apps get icons/.desktop/XDG integration on Ubuntu.
  targets.genericLinux.enable = true;

  # One Windows-style taskbar along the bottom instead of the left-hand dock
  # plus a separate top bar. Applies at the next login, not on switch.
  modules.desktopShell.enable = true;

  zenduo = {
    enable = true;
    # Run the daemons from the live checkout rather than the flake's package,
    # so an edit there is live after `systemctl --user restart duo-*`. The
    # system layer clones the repo to this path if it is missing (override
    # with ZENDUO_REPO for `make system`; keep the two in step).
    repoPath = "${config.home.homeDirectory}/p/linux-on-zenbook-duo";
    # watchBacklight / watchRotation stay off until each passes the graduation
    # protocol (linux-on-zenbook-duo/docs/DESIGN.md); flip them here when they do.
    batteryLimit = 80;
    # The built-in speakers have a ~65 dB range fed by a cubic volume slider, so
    # the bottom 40% of the slider is inaudible. The EasyEffects chain lifts the
    # average level so low/mid settings are usable — see that repo's nix/audio.nix.
    speakerDsp = true;
    # applyMethod stays "temporary" — see the option's warning: a persistent
    # apply makes gnome-shell prompt "Keep display settings?" every time, which
    # is unusable for a daemon that applies on every dock, undock and resume.
  };
}
