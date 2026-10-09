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
# vault-check, on a timer of its own, backs all of that up every two minutes:
# if the guard died or missed a signal, the check restarts it and locks the
# vault itself. It also re-checks after waking from sleep, using
# CLOCK_BOOTTIME against CLOCK_MONOTONIC (the gap between them is exactly the
# time spent asleep), so a sleep is noticed even with no guard running.
#
# WARNINGS. Anything that fails is shown three ways until it is fixed: a
# critical notification, which GNOME keeps on screen until it is dismissed;
# a red line at the top of every new terminal (vault-banner.sh); and the list
# in `vault check` and `vault status`. Repeated every four hours, and after a
# logout, a reboot or a wake, while it lasts. When it is fixed, the
# notification is replaced with one that says so. Something that went wrong
# and recovered, such as a guard crash, is shown the same way and stays until
# you have seen it in `vault check`. The check reports what it finds; if the
# check cannot run at all, systemd runs vault-alarm.sh, plain shell, instead.
# The guard and the check watch each other, so either one stopping is noticed.
#
# Every part of a lock runs on its own. If finding or closing programs fails,
# or one clean-up step does, the vault still locks and the rest still runs;
# the check retries what failed. Errors are logged by type and line only,
# because an error message can carry a file name.
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
#   - vim: a session that opens a vault file writes no ~/.viminfo.
#   - VS Code's local history skips vault files.
# Switched off for every file, because these apps have no way to leave one
# folder out (vault-check keeps them off):
#   - VLC: recent media and "continue where you left off", list emptied.
#   - LibreOffice: recent documents and their thumbnails, list emptied.
# Not preventable, so removed instead, at every lock and every check:
#   - Recent files, GNOME's list and Text Editor's own. The guard also removes
#     these the moment an entry is written. GNOME's file history
#     switch is no use here. Turning it off makes every running GTK app empty
#     the whole list, which on this machine was 1,002 entries gone in under
#     four seconds.
#   - the last folder a file chooser or Text Editor used, if it is in the vault.
#   - Text Editor's drafts and session entries for vault files.
#   - LibreOffice's crash-recovery copies of vault files.
#   - Audacity's recent files, open projects, session and logs (they name
#     every file it opens), and Xournal++'s last folders and per-document notes.
#   - Flatpak document portal entries (VLC and Kdenlive open files through
#     it), at lock.
# An app's settings are only edited while it is closed, because it writes its
# own copy back when it exits; the check gets to it after it closes.
#   - Brave's history, downloads and address-bar suggestions, and VS Code's
#     Open Recent list, workspace state and backups of unsaved vault files.
#   - Kdenlive's recent projects and folders, and its backups and autosaves
#     of vault projects. Once it has had a vault file, its whole cache goes
#     too, because frames, sound waveforms and proxy copies of the video sit
#     there and only the locked project file says whose they are. It rebuilds
#     the cache the next time you open a project.
#   - the previews and Recent entries a file leaves at its old place when it
#     is moved in: `vault add` clears them at once, the check later for a
#     file moved some other way.
#   - the clipboard, at every lock: GNOME keeps a copy after the app is gone.
# Kept out entirely: Claude Code (deny rules for its file tools and the shell
# commands it recognises), and less's search history.
# If an app prints a vault file name into the system log anyway, the check
# counts such lines (never reads them out) and warns, with how to wipe the log.
#
# Not covered, because it happens on purpose or outside this machine: copying
# a file out, screenshots and recordings, printing, uploading or sharing, a
# script an AI tool writes that opens files by itself, and history Brave Sync
# already sent to your other devices. Pages of an open file can also be
# swapped to /swap.img, which is inside the LUKS disk encryption. Nor is
# Kdenlive's cache of a video it saw before you moved it into the vault:
# empty it with Manage Cached Data in Kdenlive.
#
# THE PASSWORD is the one thing this cannot hold. The first `vault open`
# creates the vault: a password of at least 12 characters, typed twice, with
# gocryptfs's key stretching at four times its default (-scryptn 18, about
# half a second per unlock). It then shows the master key and wipes it from
# the screen and the scrollback once you press Enter; `vault key` shows it
# again. Keep it in a password manager: lose it and the password, and the
# files are gone. The password reaches gocryptfs on its stdin, never on a
# command line or in an environment another program could read.
#
# EVERY EXIT IS CLEAN. Ctrl+C, Ctrl+D, a closed terminal or a wrong password
# ends with one sentence and puts back whatever was half done: the locked
# folder read-only again, thumbnails back on. A lock that has started is not
# stopped halfway: Ctrl+C waits for it to finish.

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
    export PATH="${lib.makeBinPath [ pkgs.gocryptfs pkgs.dconf pkgs.libnotify pkgs.xclip ]}:$PATH"
    export VAULT_IDLE_SECONDS=${toString (cfg.idleMinutes * 60)}
    exec ${python}/bin/python3 ${./vault.py} "$@"
  '';

  # Claude Code can read anything you can, and what it reads goes to Anthropic
  # and into its transcripts under ~/.claude. These deny rules keep its file
  # tools, and the shell commands it recognises (cat, head, tail, sed, tee,
  # redirects), out of the open vault in every mode, bypass included. They
  # cannot stop a script it writes from opening a file by itself. Edit on
  # ~/.vault keeps it from changing or deleting the encrypted files.
  claudeDeny = [
    "Read(~/Vault/**)"
    "Edit(~/Vault/**)"
    "Read(//run/user/*/vault/**)"
    "Edit(//run/user/*/vault/**)"
    "Edit(~/.vault/**)"
  ];

  # Plain shell with its own PATH, so it still runs when vault.py cannot.
  alarm = pkgs.writeShellScript "vault-alarm" ''
    export PATH="${lib.makeBinPath [ pkgs.libnotify pkgs.coreutils pkgs.gnugrep pkgs.findutils ]}:$PATH"
    exec ${pkgs.runtimeShell} ${./vault-alarm.sh} "$@"
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
        # Never stop retrying. The default gives up after five quick failures.
        StartLimitIntervalSec = 0;
      };
      Service = {
        # notify plus a watchdog: the guard says when it is listening, then
        # checks in every 20 seconds from its main loop. A guard that hangs
        # stops checking in and is restarted, the same as one that crashes.
        Type = "notify";
        NotifyAccess = "main";
        WatchdogSec = 60;
        ExecStart = "${vault}/bin/vault guard";
        # Locks at logout. A plain restart runs this too, such as the one
        # `make home` does when this unit changes, and it does nothing then:
        # it only locks while graphical-session.target is going down.
        ExecStop = "${vault}/bin/vault close --session-ending";
        Restart = "always";
        RestartSec = 2;
        # The watchdog kills with SIGABRT, which asks for a crash dump, and a
        # dump of this process can hold vault file names. vault.py also marks
        # itself non-dumpable; this is the same rule said twice.
        LimitCORE = 0;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # The backup for everything above, on a timer of its own so it does not
    # share the guard's fate. Every two minutes, and a minute after startup:
    # restarts a dead guard; locks the vault itself if the screen is locked,
    # you have been idle long enough, or the laptop slept while it was open;
    # puts a flipped thumbnail switch back; and clears any vault entry left in
    # a recent list, a thumbnail or an app's own history. A clean run writes
    # nothing and logs nothing. `vault check` runs the same thing in a
    # terminal and prints each part.
    systemd.user.services.vault-check = {
      Unit = {
        Description = "Check the vault and clear anything it left behind";
        # The check reports every failure it finds itself. This is for the
        # one it cannot: failing to run at all.
        OnFailure = [ "vault-alarm@%n.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${vault}/bin/vault check --quiet";
        # A oneshot waits forever by default, and a hung check would hold
        # off every later one without a sound. This turns a hang into a
        # failure, and so into the alarm.
        TimeoutStartSec = 90;
        LimitCORE = 0;
      };
    };
    systemd.user.services."vault-alarm@" = {
      Unit.Description = "Warn that %i failed";
      Service = {
        Type = "oneshot";
        ExecStart = "${alarm} %i";
      };
    };
    systemd.user.timers.vault-check = {
      Unit.Description = "Check the vault every two minutes";
      Timer = {
        OnStartupSec = "1min";
        OnUnitActiveSec = "2min";
        AccuracySec = "15s";
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # vim writes one ~/.viminfo for everything it did, so once a vault file is
    # open, that session writes none. Its swap and backup files already go
    # next to the file, inside the vault; noundofile keeps an undo file from
    # going anywhere else.
    home.file.".vimrc".text = lib.mkAfter ''

      " modules/vault.nix: a vault file leaves no viminfo and no undo file behind.
      augroup vault_no_history
        autocmd!
        autocmd BufReadPre,BufNewFile ~/Vault/*,/run/user/*/vault/* set viminfo= | setlocal noundofile
      augroup END
    '';

    # VS Code keeps a copy of every version of a file you save in it, under
    # ~/.config/Code/User/History. This keeps vault files out of that. Its
    # Open Recent list has no such setting.
    programs.vscode.profiles.default.userSettings = lib.mkIf config.programs.vscode.enable {
      "workbench.localHistory.exclude" = {
        "${config.home.homeDirectory}/Vault/**" = true;
        "/run/user/*/vault/**" = true;
      };
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

      . ${./vault-banner.sh}
    '';
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable ''
      . ${./vault-banner.sh}
    '';

    programs.bash.historyIgnore = lib.mkIf config.programs.bash.enable [ "*Vault*" "*/run/user/*/vault*" ];

    # less keeps what you searched for, and a search inside a vault file is a
    # piece of that file. "-" means it keeps nothing.
    home.sessionVariables.LESSHISTFILE = "-";

    # Added to whatever deny list is there, in order, and only what is
    # missing; the rest of settings.json is left alone, as modules/ai.nix
    # does for its own keys.
    home.activation.vaultClaudeDeny = lib.mkIf config.modules.ai.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        f="$HOME/.claude/settings.json"
        rules='${builtins.toJSON claudeDeny}'
        jq=${pkgs.jq}/bin/jq
        missing='(.permissions.deny // []) as $d | [$r[] | select(. as $x | $d | index($x) | not)]'
        if [ -e "$f" ] && ! $jq -e . "$f" >/dev/null 2>&1; then
          echo "⚠️ $f is not readable JSON, so Claude Code is not kept out of the vault" >&2
        elif [ ! -e "$f" ] || [ "$($jq --argjson r "$rules" "$missing | length" "$f")" != 0 ]; then
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "(dry run) would add the vault's deny rules to $f"
          else
            mkdir -p "$(dirname "$f")"
            [ -e "$f" ] || { echo '{}' > "$f"; chmod 600 "$f"; }
            mode="$(stat -c '%a' "$f")"
            tmp="$(mktemp "$f.XXXXXX")"
            if $jq --argjson r "$rules" ".permissions.deny = ((.permissions.deny // []) + ($missing))" "$f" > "$tmp" \
               && [ -s "$tmp" ]; then
              mv "$tmp" "$f" && chmod "$mode" "$f"
              echo "✅ Claude Code is kept out of the vault (deny rules in $f)"
            else
              rm -f "$tmp"
              echo "⚠️ could not add the vault's deny rules to $f" >&2
            fi
          fi
        fi
      ''
    );

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
