{ config, lib, pkgs, ... }:

# A vault: an encrypted folder at ~/Vault that locks itself and leaves no
# trace of its files outside itself.
#
#   vault open      unlock it (it is created the first time) and show it in Files
#   vault close     close everything using it, then lock it
#   vault status    whether it is open, and what is using it
#
# WHERE THINGS ARE. gocryptfs keeps the files encrypted, one by one, in
# ~/.vault. That is the folder `make backup` saves, and the only one you would
# ever copy to a cloud drive. While the vault is open gocryptfs shows the
# decrypted files at /run/user/<uid>/vault, and ~/Vault links to that. The
# mount point is under /run/user on purpose: there it never shows up as a
# drive in Files, the dock or on the desktop (checked with `gio mount -l`),
# and a reboot always leaves the vault locked.
#
# This disk is already LUKS encrypted, so the vault is about the time you are
# logged in. While it is locked, nothing running as you can read it, an AI
# agent included.
#
# WHEN IT LOCKS. vault-guard, a user service, locks it when:
#   - nothing has touched the keyboard or mouse for idleMinutes. That is
#     GNOME's own idle count, so a playing video holds it off the same way it
#     keeps the screen on.
#   - the screen locks.
#   - the laptop is about to sleep. While the vault is open the guard holds a
#     logind delay lock, so the key is out of memory before the suspend.
#   - you log out.
#
# Locking closes every program using a vault file first: anything with one
# open, mapped or on its command line, any shell sitting inside the vault,
# Flatpak apps reading one through the document portal, and apps that put one
# in a recent-files list. That last group is how Image Viewer and Text Editor
# get caught. Each keeps one process for all its windows and lets go of a file
# once it is read, so closing the vault file means closing the whole app.
# Unsaved changes in a vault file are lost. The desktop itself (GNOME Shell,
# Files, Ghostty, the portals) is never closed: a Files window on the vault
# just goes empty, and a terminal tab closes when its shell does.
#
# HIDDEN. Every file and folder in the vault is listed in its folder's
# .hidden, kept up to date as files arrive, so Files and the file chooser show
# the vault as empty until Ctrl+H. ~/Vault itself is listed in ~/.hidden.
#
# NO TRACES. Stopped before anything is written:
#   - thumbnails: GNOME's thumbnailers are switched off while the vault is open
#     and back on when it locks. gnome-desktop's thumbnail factory checks that
#     switch before every thumbnail, and flipping it leaves the cache alone.
#   - shell history: zsh drops any line that names the vault or is typed
#     inside it. bash, which has no such hook, drops lines that name it.
#   - file metadata such as Evince's last page: GNOME refuses to store any for
#     a mount under /run/user (measured).
#   - search: nothing under /run/user is indexed.
# Not preventable, so removed instead:
#   - Recent files, GNOME's list and Text Editor's own: vault entries are
#     taken out the moment they are written. GNOME's file history switch is no
#     use here. Turning it off makes every running GTK app empty the whole
#     list, which on this machine was 1,002 entries gone in under four seconds.
#   - Text Editor's drafts and session entries for vault files: at lock.
#   - Flatpak document portal entries (VLC opens files through it): at lock.
# Not covered: history an app keeps by itself, such as VLC's recent media.
#
# THE PASSWORD is the one thing this cannot hold. The first `vault open`
# creates the vault, and gocryptfs prints a master key once. Keep it in a
# password manager: lose it and the password, and the files are gone.

let
  cfg = config.modules.vault;

  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  # Nix's Python with Nix's GLib and nothing else. The interactive shell's
  # LD_LIBRARY_PATH carries a second glib (see CLAUDE.md), and mixing the two
  # is how GSettings goes blind. fuse3 is kept off this PATH on purpose: its
  # fusermount3 is not setuid, and Ubuntu's in /usr/bin is the one that works.
  vault = pkgs.writeShellScriptBin "vault" ''
    unset LD_LIBRARY_PATH
    export GI_TYPELIB_PATH="${pkgs.glib.out}/lib/girepository-1.0"
    export PATH="${lib.makeBinPath [ pkgs.gocryptfs pkgs.dconf pkgs.libnotify ]}:$PATH"
    export VAULT_IDLE_SECONDS=${toString (cfg.idleMinutes * 60)}
    exec ${python}/bin/python3 ${./vault.py} "$@"
  '';
in
{
  options.modules.vault = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.modules.desktopShell.enable;
      defaultText = lib.literalExpression "config.modules.desktopShell.enable";
      example = false;
      description = ''
        The `vault` command and the vault-guard user service. On with the GNOME
        desktop, because the guard listens to GNOME for idle and screen lock.
        Nothing is created until the first `vault open`, apart from the
        ~/Vault link.
      '';
    };

    idleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = ''
        Minutes without keyboard or mouse before the vault locks itself and
        closes what it had open. The screen locking also locks the vault, so a
        shorter screen lock delay wins.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # gocryptfs too, for `gocryptfs -passwd ~/.vault` to change the password.
    home.packages = [ vault pkgs.gocryptfs ];

    systemd.user.services.vault-guard = {
      Unit = {
        Description = "Lock the vault when idle, on screen lock, before sleep and at logout";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${vault}/bin/vault guard";
        # Locks at logout. A plain restart runs this too, such as the one
        # `make home` does when this unit changes, and it does nothing then:
        # it only locks while graphical-session.target is going down.
        ExecStop = "${vault}/bin/vault close --session-ending";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    programs.zsh.initContent = lib.mkIf config.programs.zsh.enable ''
      # modules/vault.nix: a line that names the vault, or is typed while inside
      # it, never reaches history. Status 1 from this hook drops it entirely.
      _vault_no_history() {
        emulate -L zsh
        local mnt="''${XDG_RUNTIME_DIR:-/run/user/$UID}/vault"
        [[ $1 == *Vault* || $1 == *"$mnt"* ]] && return 1
        [[ $PWD == "$HOME/Vault" || $PWD == "$HOME/Vault/"* || $PWD == "$mnt" || $PWD == "$mnt/"* ]] && return 1
        return 0
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook zshaddhistory _vault_no_history
    '';

    programs.bash.historyIgnore = lib.mkIf config.programs.bash.enable [ "*Vault*" "*/run/user/*/vault*" ];

    home.activation.vault = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      link="$HOME/Vault"
      target="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vault"
      if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$target" ] || run ln -sfn "$target" "$link"
      elif [ -e "$link" ]; then
        echo "⚠️ ~/Vault exists and is not the vault's link, so it is left alone. Move it, then run make home again" >&2
      else
        run ln -s "$target" "$link"
      fi

      # Appended rather than managed, so names you add to ~/.hidden yourself stay.
      hidden="$HOME/.hidden"
      if ! { [ -f "$hidden" ] && grep -qxF Vault "$hidden"; }; then
        if [ -s "$hidden" ] && [ -n "$(tail -c1 "$hidden")" ]; then
          run sh -c 'printf "\n" >> "$1"' _ "$hidden"
        fi
        run sh -c 'printf "Vault\n" >> "$1"' _ "$hidden"
      fi
    '';
  };
}
