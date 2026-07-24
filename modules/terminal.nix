{ config, lib, pkgs, ... }:

# Terminal emulator (modules.terminal) — Ghostty, plus the desktop wiring that
# makes it the terminal this machine actually opens.
#
# Why this is its own module and not another entry in modules/apps.nix:
# `modules.apps` is the optional "desktop applications" bundle, switched off on
# WSL, off on Codespaces, and off for anyone who only wants the shell half of
# dome. The terminal is not one app among Discord and draw.io — it is the thing
# every other tool in this repo runs inside, so it must not inherit that switch.
# It is enabled from home.nix on its own terms (any machine with a desktop).
#
# Why Ghostty specifically. GNOME Terminal cannot express a modified Enter:
# VTE 0.76 implements neither the Kitty keyboard protocol nor xterm's
# modifyOtherKeys, so Shift+Enter and Enter both arrive as a bare CR and no
# terminal application can tell them apart. Checked, not assumed:
#
#   gnome-terminal --version                  -> GNOME Terminal 3.52.0 using VTE 0.76.0
#   strings libvte-2.91.so.0.7600.0 | grep -ci kitty        -> 0
#   strings libvte-2.91.so.0.7600.0 | grep -i modifyOtherKeys -> (nothing)
#
# Ghostty implements the Kitty protocol, so Shift+Enter arrives as CSI 13;2u and
# Claude Code's `shift+enter` binding (modules/ai.nix) can fire. Claude Code's
# own /terminal-setup agrees on the list: "iTerm2, WezTerm, Ghostty, Kitty, Warp
# and Windows Terminal support Shift+Enter natively."
#
# GNOME Terminal is deliberately left installed. It is Ubuntu's fallback and
# costs nothing to keep, and a terminal is a bad thing to have exactly one of.

let
  cfg = config.modules.terminal;
  ghostty = pkgs.ghostty;

  # Ghostty's own .desktop entry with two changes and nothing else, so upstream
  # keeps owning the content (name, categories, keywords, the new-window action,
  # the X-TerminalArg* hints that tell GNOME how to pass it a command):
  #
  #   Icon=  themed name -> absolute path. gnome-shell never sees
  #          ~/.nix-profile (modules/apps.nix has the full account), so a themed
  #          icon name resolves to nothing and the launcher is a blank tile.
  #
  #   DBusActivatable=  dropped. It asks GNOME to start Ghostty over D-Bus,
  #          which requires share/dbus-1/services/com.mitchellh.ghostty.service
  #          to be on the session bus's search path — and that path is
  #          XDG_DATA_DIRS again, so it is not there. Removing the line makes
  #          GNOME run Exec= directly. Single-instance behaviour is unaffected:
  #          that comes from GApplication owning a bus name at run time, not
  #          from an activation file.
  #
  # Exec= and TryExec= are already absolute /nix/store paths in nixpkgs' build,
  # so unlike every app in modules/apps.nix they need no rewriting.
  desktopEntry = pkgs.runCommand "dome-ghostty-desktop" { } ''
    src="${ghostty}/share/applications/${cfg.desktopId}"
    if [ ! -f "$src" ]; then
      echo "modules.terminal: ghostty no longer ships ${cfg.desktopId}" >&2
      echo "available:" >&2
      ls "${ghostty}/share/applications" >&2 || true
      exit 1
    fi

    grep -v '^DBusActivatable=' "$src" > entry.desktop

    icon="$(sed -nE 's/^Icon=(.*)$/\1/p' entry.desktop | head -n1)"
    case "$icon" in
      "" | /*) ;;
      *)
        for candidate in \
          "${ghostty}/share/icons/hicolor/scalable/apps/$icon.svg" \
          "${ghostty}/share/icons/hicolor/1024x1024/apps/$icon.png" \
          "${ghostty}/share/icons/hicolor/512x512/apps/$icon.png" \
          "${ghostty}/share/icons/hicolor/256x256/apps/$icon.png" \
          "${ghostty}/share/icons/hicolor/128x128/apps/$icon.png"; do
          if [ -e "$candidate" ]; then
            sed -i -E "s|^Icon=.*|Icon=$candidate|" entry.desktop
            break
          fi
        done
        ;;
    esac

    if ! grep -q '^Icon=/' entry.desktop; then
      echo "modules.terminal: could not resolve Ghostty's icon to a file" >&2
      exit 1
    fi

    install -Dm444 entry.desktop "$out/share/applications/${cfg.desktopId}"
  '';

  # Point GNOME's "default terminal" at Ghostty.
  #
  # This single key is also what Ctrl+Alt+T uses — gsd-media-keys resolves the
  # shortcut through it rather than hard-coding a terminal:
  #
  #   strings /usr/libexec/gsd-media-keys | grep default-applications
  #     org.gnome.desktop.default-applications.terminal
  #
  # so setting it is enough. No custom keybinding is registered and the stock
  # <Primary><Alt>t binding is left exactly as it is; it just opens Ghostty now.
  # Nautilus's "Open in Terminal" and everything else that honours the key
  # follow along for free.
  #
  # exec-arg stays '-e': Ghostty takes `-e <command>` — its own entry declares
  # X-TerminalArgExec=-e — which is the convention this key was designed around.
  #
  # The value must be the absolute /nix/store path: the GNOME session's PATH has
  # no Nix profile in it, so a bare `ghostty` would not resolve.
  terminalSetup = pkgs.writeShellScript "terminal-setup" ''
    # terminal-setup — makes Ghostty this session's default terminal.
    # Installed as ~/.local/bin/terminal-setup so it can be re-run by hand after
    # a login. Best-effort by design: never fail a switch over desktop glue.
    set -o pipefail

    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.glib ]}:/usr/bin:/bin:''${PATH:-}"

    log()  { printf '[terminal] %s\n' "$*"; }
    warn() { printf '[terminal:warn] %s\n' "$*" >&2; }

    # Same rule as apps-setup, and for the same reason: prefer the distro's
    # gsettings (it knows Ubuntu's compiled schemas) and strip LD_LIBRARY_PATH,
    # or a system binary loads Nix's libgio, finds no dconf GIO module, and
    # silently writes to the keyfile backend that GNOME never reads.
    clean_env() { env -u LD_LIBRARY_PATH -u GIO_MODULE_DIR -u GIO_EXTRA_MODULES "$@"; }
    gs() { if [ -x /usr/bin/gsettings ]; then clean_env /usr/bin/gsettings "$@"; else clean_env gsettings "$@"; fi; }

    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      log "no D-Bus session — skipping (run 'terminal-setup' from your desktop)"
      exit 0
    fi
    if ! gs list-schemas 2>/dev/null | grep -qx org.gnome.desktop.default-applications; then
      log "no GNOME default-applications schema — not a GNOME session, nothing to set"
      exit 0
    fi

    want="${ghostty}/bin/ghostty"
    have="$(gs get org.gnome.desktop.default-applications.terminal exec 2>/dev/null | sed -e "s/^'//" -e "s/'\$//")"

    if [ "$have" = "$want" ]; then
      log "default terminal is already Ghostty"
      exit 0
    fi

    if ! gs set org.gnome.desktop.default-applications.terminal exec "$want"; then
      warn "could not write org.gnome.desktop.default-applications.terminal exec"
      exit 0
    fi
    gs set org.gnome.desktop.default-applications.terminal exec-arg '-e' \
      || warn "could not write exec-arg (Open in Terminal may not pass commands through)"

    # Read it back out of dconf. A GSettings write can land in a backend nobody
    # reads and still exit 0 — see the clean_env note above — so "it returned
    # success" is not evidence anything changed.
    if [ -x /usr/bin/dconf ] &&
       [ "$(clean_env /usr/bin/dconf read /org/gnome/desktop/default-applications/terminal/exec 2>/dev/null | sed -e "s/^'//" -e "s/'\$//")" != "$want" ]; then
      warn "wrote the default terminal but dconf does not have it — the write went to another backend"
      warn "  check: dconf read /org/gnome/desktop/default-applications/terminal/exec"
      exit 0
    fi

    log "default terminal set to Ghostty (Ctrl+Alt+T, and Open in Terminal)"
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.packages = [ ghostty ];

    # Ghostty sets TERM=xterm-ghostty and ships the terminfo entry to match.
    # Ubuntu's ncurses has never heard of it (`infocmp xterm-ghostty` fails on a
    # stock 24.04), and the copy in ~/.nix-profile/share/terminfo is invisible to
    # /usr/bin binaries, so without this every system ncurses tool — vim, htop,
    # less, clear — dies with "unknown terminal type" inside Ghostty.
    #
    # ~/.terminfo is the one database directory ncurses searches unprompted, on
    # both the Nix and the Ubuntu build, so dropping the entries there fixes it
    # for every binary at once and needs no environment variable. Both names are
    # installed: `ghostty` is the entry's canonical name, `xterm-ghostty` the
    # value of TERM.
    home.file = {
      ".terminfo/x/xterm-ghostty".source = "${ghostty}/share/terminfo/x/xterm-ghostty";
      ".terminfo/g/ghostty".source = "${ghostty}/share/terminfo/g/ghostty";

      # Ghostty's config is a plain key = value file it reads at startup and on
      # `ghostty +reload-config`, so it is a natural fit for a managed file.
      # Every key below was checked against `ghostty +show-config --default`
      # rather than remembered, and only settings that differ from Ghostty's
      # default are listed — the rest are upstream's problem, not ours.
      ".config/ghostty/config".text = ''
        # Managed by dome (modules/terminal.nix). Edits here are overwritten on
        # the next `make home`; change the module instead.

        # Shift+Enter needs nothing configured: Ghostty speaks the Kitty
        # keyboard protocol, so a modified Enter reaches the application as
        # CSI 13;2u and Claude Code's shift+enter binding fires. That protocol
        # is the entire reason this terminal is here — see the module header.

        # Follow GNOME's light/dark preference instead of picking a side.
        window-theme = system

        # Ghostty's default is 2px, which puts the text right against the frame.
        window-padding-x = 8
        window-padding-y = 6

        # Ghostty copies the selection to the clipboard by default; GNOME
        # Terminal does not, and neither does anything else on this desktop.
        # Left on, dragging to highlight a line of output would quietly replace
        # whatever was on the clipboard — including a screenshot on its way into
        # Claude Code, which reads the clipboard on every paste.
        copy-on-select = false

        # Get the pointer out of the way while typing; it comes back on the
        # next mouse move.
        mouse-hide-while-typing = true
      '';

      ".local/bin/terminal-setup".source = terminalSetup;
    };

    # gnome-shell only ever reads ~/.local/share/applications — the whole
    # rationale is in modules/apps.nix's header.
    xdg.dataFile."applications/${cfg.desktopId}".source =
      "${desktopEntry}/share/applications/${cfg.desktopId}";

    # AFTER linkGeneration, like the apps module's own hook: the entry has to
    # exist on disk before anything is pointed at it.
    home.activation.terminalDefault = lib.mkIf cfg.setDefault (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "(dry run) would make Ghostty the GNOME default terminal"
        else
          ${terminalSetup} || echo "⚠️ terminal-setup did not finish — re-run it from a desktop session" >&2
        fi
      ''
    );
  };
}
