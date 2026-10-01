{ config, lib, pkgs, ... }:

# OBS recording hotkeys that work when OBS is not the focused window.
#
# THE PROBLEM. OBS's own global hotkeys are built on X11's XGrabKey. Wayland
# refuses to let an application grab a key it does not have focus for, so on
# this GNOME Wayland session the hotkeys set in OBS only fire while the OBS
# window is focused, which is the one moment you do not need them. No OBS
# setting changes that and nothing in this repo caused it.
#
# THE FIX. Put the grab where it is allowed. A GNOME custom shortcut is grabbed
# by the compositor, so it fires from anywhere, and it runs obs-hotkey, which
# turns the keypress into an obs-websocket request. OBS has carried
# obs-websocket since version 28, so there is no plugin to install, only a
# server to switch on.
#
# WHY NOT THE TWO OBVIOUS ALTERNATIVES. Running OBS on XWayland
# (QT_QPA_PLATFORM=xcb) does bring XGrabKey back, but XWayland only sees the
# grab while an XWayland window has focus, so it fails in exactly the case that
# matters. Moving the whole session to X11 works and costs the Duo dock policy,
# which drives Mutter over D-Bus.
#
# THE KEYS match what OBS's own profile already has in
# basic/profiles/*/basic.ini, so pressing them focused or unfocused does the
# same thing:
#
#   Ctrl+Shift+F8   start and stop recording
#   Ctrl+Shift+F9   pause and resume recording
#
# OBS's copies are left alone. They still work when it is focused, and two
# grabs of the same key do not clash because only one of them is ever live.

let
  apps = config.modules.apps;
  shell = config.modules.desktopShell;

  # Gated the way modules/xournalpp.nix is: this configures an app that bundle
  # installs, so there is nothing to do on a machine without it, and `skip` is
  # honoured because a machine running its own OBS from apt should keep its own
  # settings. desktopShell as well, since the shortcuts are dconf keys that
  # only GNOME reads.
  enabled = apps.enable && !(lib.elem "obs-studio" apps.skip) && shell.enable;

  wsConf = "${config.xdg.configHome}/obs-studio/plugin_config/obs-websocket/config.json";

  # PATH is baked in because gsd-media-keys execs a shortcut's command directly
  # rather than through a login shell, so the command starts with almost no
  # environment. The script itself is a separate file so it stays readable and
  # shellcheck can be run on it on its own. runtimeShell is the same bash
  # writeShellScriptBin puts in the shebang, so naming it adds nothing to the
  # closure, where pkgs.bash would have dragged in bash-interactive.
  obsHotkey = pkgs.writeShellScriptBin "obs-hotkey" ''
    export PATH="${lib.makeBinPath [ pkgs.obs-cmd pkgs.jq pkgs.libnotify pkgs.coreutils ]}:$PATH"
    exec ${pkgs.runtimeShell} ${./obs-hotkey.sh} "$@"
  '';

  root = "org/gnome/settings-daemon/plugins/media-keys";

  shortcuts = {
    obs-record-toggle = {
      name = "OBS: start or stop recording";
      command = "${obsHotkey}/bin/obs-hotkey recording toggle";
      binding = "<Control><Shift>F8";
    };
    obs-record-pause = {
      name = "OBS: pause or resume recording";
      command = "${obsHotkey}/bin/obs-hotkey recording toggle-pause";
      binding = "<Control><Shift>F9";
    };
  };
in
{
  config = lib.mkIf enabled {
    home.packages = [ obsHotkey ];

    # Every value here is a string or a list of strings, which is what the
    # schema declares: `gsettings range org.gnome.settings-daemon.plugins
    # .media-keys custom-keybindings` reports `as`, and name, command and
    # binding are each `s`. So none of them needs the lib.hm.gvariant wrapping
    # CLAUDE.md warns about, which applies to numbers.
    #
    # custom-keybindings is the index. gsd-media-keys reads only the paths
    # listed in it and opens each one with the relocatable
    # ...media-keys.custom-keybinding schema. That last path segment is a name
    # and not an ordinal, so these are called what they are rather than custom0
    # and custom1; GNOME Settings keeps allocating customN for anything added
    # by hand, so the two numbering schemes cannot collide.
    #
    # DECLARED, NOT SEEDED, the same contract as the app grid in
    # modules/desktop-shell.nix: this list is re-asserted on every `make home`,
    # so a shortcut added in GNOME Settings is dropped at the next switch. Add
    # shortcuts here, not in the GUI.
    dconf.settings = {
      "${root}".custom-keybindings =
        lib.mapAttrsToList (n: _: "/${root}/custom-keybindings/${n}/") shortcuts;
    }
    // lib.mapAttrs' (n: v: lib.nameValuePair "${root}/custom-keybindings/${n}" v) shortcuts;

    # obs-websocket ships with the server off. OBS rewrites this file whenever
    # its settings change, so it cannot be a managed symlink any more than
    # ~/.claude.json can; it is merged with jq instead, on the same reasoning as
    # modules/ai.nix. Only server_enabled is written. Every other key, the
    # password OBS generated included, is passed through, and nothing from the
    # file is read into the repo or the store.
    home.activation.obsWebsocket = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.procps ]}:$PATH"

      if [ ! -e "${wsConf}" ]; then
        echo "ℹ️ OBS has not written its WebSocket config yet. Start OBS once, then 'make home' again to switch the server on"
      elif ! jq -e . "${wsConf}" >/dev/null 2>&1; then
        echo "⚠️ ${wsConf} is not readable JSON, so it is left alone. Switch the server on in OBS: Tools > WebSocket Server Settings" >&2
      elif [ "$(jq -r '.server_enabled' "${wsConf}")" = "true" ]; then
        :   # already on, so do not touch the file and do not disturb its mtime
      elif [ -n "''${DRY_RUN_CMD:-}" ]; then
        echo "(dry run) would set server_enabled = true in ${wsConf}"
      else
        # Temp file beside the target so the swap is an atomic rename on the
        # same filesystem, and nothing replaces the original unless jq produced
        # parseable, non-empty output: a botched merge here loses the password
        # and every obs-websocket client has to be re-paired.
        tmp="$(mktemp "${wsConf}.XXXXXX")"
        if jq '.server_enabled = true' "${wsConf}" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mode="$(stat -c '%a' "${wsConf}" 2>/dev/null || echo 644)"
          mv "$tmp" "${wsConf}" && chmod "$mode" "${wsConf}"
          echo "✅ OBS WebSocket server switched on (127.0.0.1, password auth, port from its own config)"
          # OBS writes this file back out when it exits, so a copy running now
          # would undo the line above without saying anything.
          if pgrep -f 'obs-studio-[0-9][^ ]*/bin/' >/dev/null 2>&1; then
            echo "⚠️ OBS is running and rewrites that file on exit, so close it and run 'make home' again" >&2
          fi
        else
          rm -f "$tmp"
          echo "⚠️ could not update ${wsConf}. Switch the server on in OBS: Tools > WebSocket Server Settings" >&2
        fi
      fi
    '';
  };
}
