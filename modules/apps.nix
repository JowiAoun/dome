{ config, lib, pkgs, ... }:

# Desktop applications (modules.apps) — GUI software plus the desktop wiring
# that makes it usable: real .desktop entries, the default browser, and the
# GNOME dash pins.
#
# Why the .desktop entries are rebuilt here instead of just installing the
# packages: on Ubuntu the GNOME session does NOT see the Nix profile. Checked on
# this machine (`tr '\0' '\n' < /proc/$(pgrep -x gnome-shell)/environ`):
#
#   XDG_DATA_DIRS=/usr/local/share/:/usr/share/:/var/lib/snapd/desktop
#   PATH=$HOME/.npm-global/bin:/usr/local/sbin:...:/snap/bin
#
# Neither contains ~/.nix-profile, so gnome-shell never reads
# ~/.nix-profile/share/applications and cannot resolve a bare `Exec=discord`
# or a themed `Icon=discord`. (home-manager's targets.genericLinux DOES write an
# XDG_DATA_DIRS line into ~/.config/environment.d/10-home-manager.conf, but it
# uses shell syntax — ''${NIX_STATE_DIR:-/nix/var/nix} — that systemd's
# environment.d parser does not support, so systemd drops the assignment.)
#
# So each app's entry is copied into ~/.local/share/applications (which is
# XDG_DATA_HOME and therefore ALWAYS scanned) with Exec/TryExec/Icon rewritten
# to absolute /nix/store paths. That works in the current session, with no
# re-login and no changes to the session environment.

let
  cfg = config.modules.apps;

  # GUI apps that get the full treatment: package + patched desktop entries
  # (+ dash pin where pin = true). `ids` are the .desktop file names inside
  # ${package}/share/applications — read off the built packages, not guessed
  # (LocalSend's is capitalised; VS Code ships two). The first id is the one
  # that gets pinned. To add an app, add a line here.
  #
  # probeDesktop/probeCommands answer "does this machine already have this app
  # from apt/snap/flatpak?", so an existing install is never duplicated or
  # overridden. setup.sh has the same table (shell side of the same question) —
  # keep them in sync when adding an app.
  desktopApps = [
    {
      name = "brave";
      package = pkgs.brave;
      ids = [ "brave-browser.desktop" ];  # also ships com.brave.Browser.desktop; one launcher is enough
      pin = true;
      browser = true;                     # -> default handler for http/https/html
      probeDesktop = [ "brave-browser.desktop" "brave.desktop" "com.brave.Browser.desktop" "brave_brave.desktop" ];
      probeCommands = [ "brave-browser" "brave" ];
    }
    {
      name = "discord";
      package = pkgs.discord;
      ids = [ "discord.desktop" ];        # Exec=Discord — bare name, needs patching
      pin = true;
      browser = false;
      probeDesktop = [ "discord.desktop" "com.discordapp.Discord.desktop" "discord_discord.desktop" ];
      probeCommands = [ "discord" "Discord" ];
    }
    {
      name = "drawio";
      package = pkgs.drawio;
      ids = [ "drawio.desktop" ];
      pin = false;                        # installed, not pinned
      browser = false;
      probeDesktop = [ "drawio.desktop" "com.jgraph.drawio.desktop.desktop" "drawio_drawio.desktop" ];
      probeCommands = [ "drawio" ];
    }
    {
      name = "localsend";
      package = pkgs.localsend;
      ids = [ "LocalSend.desktop" ];      # capital L, and Exec=localsend_app
      pin = false;
      browser = false;
      probeDesktop = [ "LocalSend.desktop" "localsend.desktop" "org.localsend.localsend_app.desktop" "localsend_localsend.desktop" ];
      probeCommands = [ "localsend" "localsend_app" ];
    }
    {
      name = "bruno";
      package = pkgs.bruno;
      ids = [ "bruno.desktop" ];
      pin = false;
      browser = false;
      probeDesktop = [ "bruno.desktop" "com.usebruno.Bruno.desktop" "bruno_bruno.desktop" ];
      probeCommands = [ "bruno" ];
    }
    {
      name = "obs-studio";
      package = pkgs.obs-studio;
      ids = [ "com.obsproject.Studio.desktop" ];
      pin = false;
      browser = false;
      probeDesktop = [ "com.obsproject.Studio.desktop" "obs-studio.desktop" "obs-studio_obs-studio.desktop" ];
      probeCommands = [ "obs" "obs-studio" ];
    }
  ];

  # VS Code is installed by home-manager's programs.vscode (home.nix), not by
  # this module — but it has exactly the same problem as the apps above: its
  # entry has a bare `Exec=code` and a themed `Icon=vscode`, and nothing in
  # ~/.nix-profile is visible to gnome-shell, so it never appears in the app
  # grid at all. Give it the same patched entries. code-url-handler.desktop is
  # what makes vscode:// links work.
  vscodeApp = {
    name = "vscode";
    package = config.programs.vscode.package;
    ids = [ "code.desktop" "code-url-handler.desktop" ];
    pin = false;
    browser = false;
    probeDesktop = [ "code.desktop" "visual-studio-code.desktop" "code_code.desktop" "com.visualstudio.code.desktop" ];
    probeCommands = [ "code" ];
  };

  # Apps listed in modules.apps.skip are dropped entirely: no package, no
  # desktop entry, no pin, never the default browser. setup.sh fills this in
  # automatically for anything it finds already installed outside Nix
  # (./setup.sh --sync-apps-skip), and you can add names by hand.
  knownNames = map (a: a.name) (desktopApps ++ [ vscodeApp ]);
  unknownSkips = lib.filter (n: !(lib.elem n knownNames)) cfg.skip;
  selected = lib.warnIf (unknownSkips != [ ])
    "modules.apps.skip: unknown app name(s) ${lib.concatStringsSep ", " unknownSkips} (known: ${lib.concatStringsSep ", " knownNames})"
    (lib.filter (a: !(lib.elem a.name cfg.skip)) desktopApps);

  # Anything named in modules.apps.extras. These are plain packages: they are
  # installed into the profile but get no patched desktop entry, so a GUI extra
  # only shows up in the dash if it ships an absolute Exec= (many nixpkgs GUI
  # packages do). Promote one to a first-class entry by moving it into
  # desktopApps above.
  extraPkgs = map
    (n: pkgs.${n} or (throw "modules.apps.extras: nixpkgs has no package named '${n}'"))
    cfg.extras;

  # Copy one .desktop entry out of a package, making every path absolute.
  patchDesktop = app: id: pkgs.runCommand "dome-desktop-${id}" { } ''
    src="${app.package}/share/applications/${id}"
    if [ ! -f "$src" ]; then
      echo "modules.apps: ${app.package.name} does not ship ${id}" >&2
      echo "available:" >&2
      ls "${app.package}/share/applications" >&2 || true
      exit 1
    fi

    # Exec=/TryExec= — prefix a bare command name with the package's bin dir.
    # Entries that are already absolute (brave) are left alone by the
    # "first character is not /" guard.
    sed -E \
      -e 's|^(Exec=)([^/[:space:]][^[:space:]]*)|\1${app.package}/bin/\2|' \
      -e 's|^(TryExec=)([^/[:space:]][^[:space:]]*)|\1${app.package}/bin/\2|' \
      "$src" > entry.desktop

    # Icon= — a themed name resolves through XDG_DATA_DIRS, so point it at the
    # actual file. Preference order: scalable, then largest raster.
    icon="$(sed -nE 's/^Icon=(.*)$/\1/p' entry.desktop | head -n1)"
    case "$icon" in
      "" | /*) ;;
      *)
        for candidate in \
          "${app.package}/share/icons/hicolor/scalable/apps/$icon.svg" \
          "${app.package}/share/icons/hicolor/1024x1024/apps/$icon.png" \
          "${app.package}/share/icons/hicolor/512x512/apps/$icon.png" \
          "${app.package}/share/icons/hicolor/256x256/apps/$icon.png" \
          "${app.package}/share/icons/hicolor/128x128/apps/$icon.png" \
          "${app.package}/share/icons/hicolor/64x64/apps/$icon.png" \
          "${app.package}/share/pixmaps/$icon.svg" \
          "${app.package}/share/pixmaps/$icon.png"; do
          if [ -e "$candidate" ]; then
            sed -i -E "s|^Icon=.*|Icon=$candidate|" entry.desktop
            break
          fi
        done
        ;;
    esac

    install -Dm444 entry.desktop "$out/share/applications/${id}"
  '';

  # One xdg.dataFile entry per .desktop file an app ships.
  entriesFor = app: map (id: {
    name = "applications/${id}";
    value.source = "${patchDesktop app id}/share/applications/${id}";
  }) app.ids;

  patched = map (app: app // { entryDirs = map (patchDesktop app) app.ids; }) selected;

  browserApp = lib.findFirst (a: a.browser) null patched;
  browserId = if browserApp == null then "" else builtins.head browserApp.ids;
  browserName = if browserApp == null then "" else browserApp.name;

  # Ubuntu 24.04 pins the Firefox snap as firefox_firefox.desktop; the other
  # names cover a deb/flatpak install of the same browser.
  unpinIds = [
    "firefox_firefox.desktop"
    "firefox.desktop"
    "firefox-esr.desktop"
    "org.mozilla.firefox.desktop"
  ];

  # Desktop state GNOME keeps in dconf/mimeapps.list — not expressible as Nix
  # files, so it is reconciled by a small idempotent script instead. Run by the
  # activation hook below and installed as ~/.local/bin/apps-setup so it can be
  # re-run by hand after a login.
  appsSetup = pkgs.writeShellScript "apps-setup" ''
    # apps-setup — desktop integration for dome's `apps` module.
    #
    #   1. make ${browserId} the default browser (mimeapps.list, via gio)
    #   2. merge the GNOME dash pins: add this module's apps, drop Firefox
    #
    # MERGE, not overwrite: favourites are something you rearrange by hand all
    # the time, so anything you pinned yourself survives. Deliberately no
    # `set -e` — desktop glue is best-effort and must never fail a switch on a
    # machine without GNOME.
    set -o pipefail

    export PATH="${lib.makeBinPath [
      pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.glib pkgs.desktop-file-utils
    ]}:/usr/bin:/bin:''${PATH:-}"

    # Resolve the entries straight out of the store, so this works even when it
    # runs before ~/.local/share/applications has been linked.
    export XDG_DATA_DIRS="${lib.concatMapStringsSep ":" (d: "${d}/share") (lib.concatMap (a: a.entryDirs) patched)}:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

    log()  { printf '[apps] %s\n' "$*"; }
    warn() { printf '[apps:warn] %s\n' "$*" >&2; }

    # Run the distro's glib tools with a CLEAN library path.
    #
    # Both halves matter. Prefer /usr/bin: its gsettings knows Ubuntu's
    # compiled schemas. And drop LD_LIBRARY_PATH, because home.nix exports
    # Nix's glib on it (pip packages with binary deps need it) — so a system
    # binary loads Nix's libgio, which ships no gio/modules, which means no
    # libdconfsettings.so, which means GSettings silently falls back to the
    # keyfile backend in ~/.config/glib-2.0/settings/keyfile. GNOME Shell reads
    # dconf and never looks there, so every write "succeeds" and changes
    # nothing: the dash kept Firefox and never showed Brave, while this script
    # cheerfully reported "dash pins already up to date" by reading its own
    # keyfile back. Nothing warns; the two stores just drift apart.
    clean_env() { env -u LD_LIBRARY_PATH -u GIO_MODULE_DIR -u GIO_EXTRA_MODULES "$@"; }
    gs()   { if [ -x /usr/bin/gsettings ]; then clean_env /usr/bin/gsettings "$@"; else clean_env gsettings "$@"; fi; }
    gio_() { if [ -x /usr/bin/gio ];       then clean_env /usr/bin/gio "$@";       else clean_env gio "$@";       fi; }

    in_list() {
      local needle="$1" item
      shift
      for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
      done
      return 1
    }

    # ── 0. hands off anything the machine already has ────────────────────────
    # If Brave (or Discord, or draw.io) is already installed from apt, snap or
    # flatpak, that copy owns its pin and its defaults — we touch neither.
    # Only system locations are searched: looking in ~/.nix-profile or
    # ~/.local/share/applications would find the copies this module just
    # installed and make it disown them on the very next run.
    foreign_copy() { # <app name> -> path of a non-Nix copy, if any
      local name="$1" desktops="" commands="" dir id cmd
      case "$name" in
    ${lib.concatMapStringsSep "\n" (a: ''
      ${a.name}) desktops=${lib.escapeShellArg (lib.concatStringsSep " " a.probeDesktop)}; commands=${lib.escapeShellArg (lib.concatStringsSep " " a.probeCommands)} ;;'') patched}
        *) return 1 ;;
      esac
      for dir in /usr/share/applications /usr/local/share/applications \
                 /var/lib/snapd/desktop/applications \
                 /var/lib/flatpak/exports/share/applications \
                 "$HOME/.local/share/flatpak/exports/share/applications"; do
        for id in $desktops; do
          if [ -e "$dir/$id" ]; then
            printf '%s\n' "$dir/$id"
            return 0
          fi
        done
      done
      for dir in /usr/bin /usr/local/bin /snap/bin /opt/bin; do
        for cmd in $commands; do
          if [ -x "$dir/$cmd" ]; then
            printf '%s\n' "$dir/$cmd"
            return 0
          fi
        done
      done
      return 1
    }

    FOREIGN=""
    find_foreign() {
      local name where
      for name in ${lib.concatMapStringsSep " " (a: lib.escapeShellArg a.name) patched}; do
        if where="$(foreign_copy "$name")"; then
          warn "$name is already installed outside Nix ($where) — leaving it alone"
          warn "  (not pinning it, not changing its defaults)"
          warn "  to stop installing the Nix copy as well: ./setup.sh --sync-apps-skip && make home"
          FOREIGN="$FOREIGN $name"
        fi
      done
    }
    is_foreign() { case " $FOREIGN " in *" $1 "*) return 0 ;; esac; return 1; }

    # ── 1. default browser ───────────────────────────────────────────────────
    set_default_browser() {
      local id="${browserId}" mimeapps type
      [ -n "$id" ] || return 0
      if is_foreign ${lib.escapeShellArg browserName}; then return 0; fi
      mimeapps="''${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
      # Read the file rather than parsing `gio mime` output, which is
      # translated and would stop matching under a non-English locale.
      if grep -qE "^x-scheme-handler/https=$id(;|$)" "$mimeapps" 2>/dev/null; then
        log "default browser is already $id"
        return 0
      fi
      for type in x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml; do
        gio_ mime "$type" "$id" >/dev/null 2>&1 || warn "could not set $type -> $id"
      done
      log "default browser set to $id"
    }

    # ── 2. dash pins ─────────────────────────────────────────────────────────
    merge_dash_pins() {
      local raw cleaned joined="" entry pair name id
      local -a current=() merged=() pins=()
      local -a unpins=(${lib.escapeShellArgs unpinIds})

      # "name:id" pairs so a pin can be dropped by app name when the machine
      # already provides that app itself.
      for pair in ${lib.concatMapStringsSep " " (a: lib.escapeShellArg "${a.name}:${builtins.head a.ids}") (lib.filter (a: a.pin) patched)}; do
        name="''${pair%%:*}"
        is_foreign "$name" || pins+=("''${pair#*:}")
      done

      if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        log "no D-Bus session — skipping dash pins (run 'apps-setup' from your desktop)"
        return 0
      fi
      if ! gs list-schemas 2>/dev/null | grep -qx org.gnome.shell; then
        log "no org.gnome.shell schema — not a GNOME session, skipping dash pins"
        return 0
      fi

      raw="$(gs get org.gnome.shell favorite-apps 2>/dev/null)" || return 0
      # "['a.desktop', 'b.desktop']" (or "@as []" when the key is empty)
      cleaned="$(printf '%s' "$raw" | sed -e 's/^@as //' -e 's/^\[//' -e 's/\]$//' -e "s/'//g" -e 's/ //g')"
      IFS=',' read -r -a current <<< "$cleaned"

      for entry in ''${current[@]+"''${current[@]}"}; do
        [ -n "$entry" ] || continue
        if in_list "$entry" ''${unpins[@]+"''${unpins[@]}"}; then
          # Reuse the slot: the new browser takes the old browser's position
          # instead of being appended to the end of the dash.
          if in_list "${browserId}" ''${pins[@]+"''${pins[@]}"} \
             && ! in_list "${browserId}" ''${merged[@]+"''${merged[@]}"}; then
            merged+=("${browserId}")
          fi
          continue
        fi
        merged+=("$entry")
      done

      for id in ''${pins[@]+"''${pins[@]}"}; do
        in_list "$id" ''${merged[@]+"''${merged[@]}"} || merged+=("$id")
      done

      for entry in ''${merged[@]+"''${merged[@]}"}; do
        joined="$joined, '$entry'"
      done
      joined="[''${joined#, }]"

      if [ "$(printf '%s' "$joined" | sed 's/ //g')" = "$(printf '%s' "$raw" | sed 's/ //g')" ]; then
        log "dash pins already up to date"
        return 0
      fi
      if ! gs set org.gnome.shell favorite-apps "$joined"; then
        warn "could not write org.gnome.shell favorite-apps"
        return 0
      fi
      # Read it back. A GSettings write can land in a backend nobody reads (see
      # the clean_env note above) and still exit 0, so "it returned success" is
      # not evidence the dash changed. Comparing against dconf directly is the
      # check that would have caught that immediately.
      if [ -x /usr/bin/dconf ] &&
         [ "$(clean_env /usr/bin/dconf read /org/gnome/shell/favorite-apps 2>/dev/null | sed 's/ //g')" \
           != "$(printf '%s' "$joined" | sed 's/ //g')" ]; then
        warn "wrote favorite-apps but dconf does not have it — the write went to another backend"
        warn "  check: dconf read /org/gnome/shell/favorite-apps"
        return 0
      fi
      log "dash pins updated: $joined"
    }

    # Refresh the MIME cache so the new entries are picked up without a re-login.
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

    find_foreign
    set_default_browser
    merge_dash_pins
  '';
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = map (a: a.package) patched ++ extraPkgs;

      # Absolute-path desktop entries in XDG_DATA_HOME — see the header comment.
      xdg.dataFile = lib.listToAttrs (lib.concatMap entriesFor patched);

      # home.nix defaults this to firefox with mkDefault, so this wins when the
      # apps module is on.
      home.sessionVariables.BROWSER = "brave";

      home.file.".local/bin/apps-setup".source = appsSetup;

      # AFTER linkGeneration, not writeBoundary. GNOME Shell renders a pinned
      # favourite only if it can resolve the .desktop id at the moment the
      # favorite-apps key changes; ids it cannot resolve are silently dropped
      # from the dash. writeBoundary runs at activation step 3 and
      # linkGeneration at step 9, so pinning from there wrote the ids before
      # ~/.local/share/applications existed — the key looked correct in dconf
      # and the icons never appeared. Worse, the next switch saw the key
      # already "up to date" and never re-pinned, so it stayed broken until the
      # next login.
      home.activation.appsDesktopIntegration = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "(dry run) would run apps-setup (default browser + GNOME dash pins)"
        else
          ${appsSetup} || echo "⚠️ apps-setup did not finish — re-run it from a desktop session" >&2
        fi
      '';
    })

    # VS Code's entries, independent of modules.apps: it is installed by
    # programs.vscode on every non-WSL host, and without this it is invisible
    # to the app grid there too. home.nix already turns programs.vscode off
    # when "vscode" is in appsSkip; the second guard keeps that true even if a
    # host profile enables it by hand.
    (lib.mkIf (config.programs.vscode.enable && !(lib.elem "vscode" cfg.skip)) {
      xdg.dataFile = lib.listToAttrs (entriesFor vscodeApp);
    })
  ];
}
