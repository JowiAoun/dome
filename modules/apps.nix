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

  # Middle click must NEVER paste — the Gecko half of that. The Chromium and
  # Electron half is chromiumFlags below; the GTK-wide half is a dconf key in
  # modules/desktop-shell.nix. Gecko needs its own because its content area is
  # neither GTK nor Blink: Thunderbird's compose window and Firefox's page area
  # are drawn by Gecko, which implements middle-click paste itself off
  # `middlemouse.paste` and ignores gtk-enable-primary-paste completely.
  #
  # This CANNOT go in the enterprise policy in system/77-gecko-policy.sh beside
  # the autoscroll pref, which is worth writing down because it looks like it
  # should. Gecko's Preferences policy only accepts prefs matching an allowlist
  # compiled into the app (modules/policies/Policies.sys.mjs, `allowedPrefixes`,
  # read out of the shipped omni.ja):
  #
  #   accessibility. app.update. browser. calendar. chat. datareporting.policy.
  #   dom. extensions. general.autoScroll general.smoothScroll geo. gfx. intl.
  #   layers. layout. mail. mailnews. media. network. pdfjs. places. print.
  #   signon. spellchecker. ui. widget.
  #
  # `middlemouse.` is absent — and note `general.autoScroll` is on that list BY
  # NAME, which is precisely why the autoscroll policy works and why this one
  # cannot be added next to it. A middlemouse pref in policies.json is dropped
  # with "Preference not allowed for stability reasons" and does nothing at all.
  #
  # autoconfig is the supported route for an arbitrary pref, and nixpkgs' Gecko
  # wrapper already wires it up — the built package ships
  # defaults/pref/autoconfig.js pointing at mozilla.cfg, and `extraPrefs` is
  # appended to that file. lockPref rather than defaultPref so it cannot be
  # switched back on by accident, and because autoconfig applies to EVERY
  # profile, including ones created later, which a per-profile user.js does not.
  geckoNoMiddleClickPaste = ''
    lockPref("middlemouse.paste", false);
    lockPref("middlemouse.contentLoadURL", false);
  '';

  # Extra command-line switches for every Chromium-based app
  # (modules.apps.chromiumFlags — middle-click autoscroll by default). Electron
  # IS Chromium, so the browser and the Electron apps share one list.
  #
  # A switch reaches a Chromium process ONLY through the command line that
  # started it: there is no config file, no policy key and no environment
  # variable for this. So every way an app can be launched has to carry it, or
  # the setting silently holds in some windows and not others — worse than not
  # setting it at all. The five ways, and who handles each:
  #
  #   nixpkgs app's own launcher   -> patchDesktop, for `chromium = true` apps
  #   apt app's own launcher       -> chromium_flag_overrides in apps-setup
  #   the web app launchers        -> webAppEntry
  #   $BROWSER                     -> browserOpener
  #   a terminal `brave-browser`   -> NOT covered; nothing owns that argv
  # NOT every Electron app forwards what it does not recognise. Most hand argv
  # straight to Chromium, but an app that parses its own can reject a switch and
  # refuse to start: Joplin ends its parser with
  #
  #   if (arg.length && arg[0] === "-") throw new Error(_("Unknown flag: %s", arg))
  #
  # having allowlisted a specific set of Chromium switches by name — including
  # --enable-features=, which is why autoscroll works there, but not
  # --blink-settings=, which put up a modal "An error occurred: Unknown flag"
  # instead of a window. (Read out of its app.asar; Joplin is unusual this way
  # because the desktop app shares CLI parsing with joplin-cli.)
  #
  # So an app can drop individual switches with `chromiumFlagsExclude`, matched
  # by PREFIX so `--blink-settings` covers any value. Excluding one costs only
  # what that switch bought — Joplin keeps autoscroll and keeps middle-click
  # paste — which beats the app not opening.
  #
  # There is no way to test this cheaply: the failure is a GUI dialog, so the
  # app still runs and prints nothing to stdout or stderr. If another app ever
  # shows that dialog, add one line to its entry here.
  chromiumFlagsFor = app:
    let excludes = app.chromiumFlagsExclude or [ ];
    in lib.filter (f: !(lib.any (p: lib.hasPrefix p f) excludes)) cfg.chromiumFlags;
  chromiumFlagsStrFor = app: lib.concatStringsSep " " (chromiumFlagsFor app);

  # The unfiltered list, for the launch paths that are always the browser.
  chromiumFlagsStr = lib.concatStringsSep " " cfg.chromiumFlags;
  # " --flag ..." or "", so call sites can concatenate unconditionally.
  chromiumFlagsSuffix = lib.optionalString (cfg.chromiumFlags != [ ]) " ${chromiumFlagsStr}";

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
      chromium = true;                    # -> modules.apps.chromiumFlags on its Exec
      probeDesktop = [ "brave-browser.desktop" "brave.desktop" "com.brave.Browser.desktop" "brave_brave.desktop" ];
      probeCommands = [ "brave-browser" "brave" ];
    }
    {
      name = "discord";
      package = pkgs.discord;
      ids = [ "discord.desktop" ];        # Exec=Discord — bare name, needs patching
      pin = true;
      browser = false;
      chromium = true;                    # Electron (opt/Discord/resources/app.asar)
      probeDesktop = [ "discord.desktop" "com.discordapp.Discord.desktop" "discord_discord.desktop" ];
      probeCommands = [ "discord" "Discord" ];
    }
    {
      name = "drawio";
      package = pkgs.drawio;
      ids = [ "drawio.desktop" ];
      pin = false;                        # installed, not pinned
      browser = false;
      chromium = true;                    # Electron (share/lib/drawio/resources/app.asar)
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
      chromium = true;                    # Electron (opt/bruno/resources/app.asar)
      probeDesktop = [ "bruno.desktop" "com.usebruno.Bruno.desktop" "bruno_bruno.desktop" ];
      probeCommands = [ "bruno" ];
    }
    {
      # Note-taking. `joplin` in nixpkgs is the CLI — the GUI is joplin-desktop.
      # Its entry is joplin.desktop, not joplin-desktop.desktop: read off the
      # joplin.desktop.drv input of the derivation rather than by building it,
      # since this one ships held back (see appsSkip).
      name = "joplin";
      package = pkgs.joplin-desktop;
      ids = [ "joplin.desktop" ];
      pin = true;
      browser = false;
      chromium = true;                    # Electron (share/joplin-desktop/resources/app.asar)
      # Joplin takes NO chromiumFlags, for two unrelated reasons.
      #
      # --blink-settings  it rejects outright. Joplin parses its own argv and
      #                   throws "Unknown flag" on anything not in its allowlist,
      #                   which put up a modal error dialog instead of a window.
      #                   See the note on chromiumFlagsFor above.
      #
      # --enable-features autoscroll itself, dropped by choice. It worked here,
      #                   but in an editable area Blink also drags the text caret
      #                   to wherever the middle button went down, and nothing
      #                   can separate the two: the caret placement and the
      #                   autoscroll start are both default behaviour of the same
      #                   mousedown (see the KNOWN LIMITATION note on
      #                   modules.apps.chromiumFlags). In a notes editor a caret
      #                   that jumps mid-edit costs more than panning saves, so
      #                   Joplin keeps a still caret and scrolls by wheel.
      #
      # This empties Joplin's list, so patchDesktop adds no switches at all.
      chromiumFlagsExclude = [ "--blink-settings" "--enable-features" ];
      probeDesktop = [ "joplin.desktop" "joplin-desktop.desktop" "net.cozic.joplin_desktop.desktop" "joplin_joplin.desktop" ];
      probeCommands = [ "joplin-desktop" "joplin" ];
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
    {
      # The official Mozilla build. Ubuntu ships Thunderbird as a snap on
      # installs that include it, so thunderbird_thunderbird.desktop is in the
      # probe list: if the machine already has it, this copy is not installed
      # and the existing one keeps owning mailto:.
      name = "thunderbird";
      # extraPrefs, not the policies.json in system/77-gecko-policy.sh: the
      # policy engine rejects middlemouse.* outright. See geckoNoMiddleClickPaste.
      package = pkgs.thunderbird.override { extraPrefs = geckoNoMiddleClickPaste; };
      ids = [ "thunderbird.desktop" ];  # Exec=thunderbird, Icon=thunderbird — both need patching
      pin = true;
      browser = false;
      mailer = true;                    # -> default handler for mailto: and .eml
      probeDesktop = [ "thunderbird.desktop" "mozilla-thunderbird.desktop" "net.thunderbird.Thunderbird.desktop" "thunderbird_thunderbird.desktop" ];
      probeCommands = [ "thunderbird" ];
    }
    {
      # nixpkgs rewrites the shipped entry to a bare `Exec=zoom`, so it needs
      # the same absolute-path patching as everything else here.
      name = "zoom";
      package = pkgs.zoom-us;
      ids = [ "Zoom.desktop" ];         # capital Z, like LocalSend
      pin = false;
      browser = false;
      probeDesktop = [ "Zoom.desktop" "zoom.desktop" "us.zoom.Zoom.desktop" "zoom-client_zoom-client.desktop" ];
      probeCommands = [ "zoom" "zoom-us" ];
    }
    {
      # GTK4/libadwaita weather dashboard (Open-Meteo backed). Ships a bare
      # Exec=mousam and a themed Icon, so it needs the usual absolute-path
      # patching. Its entry is the reverse-DNS id, not mousam.desktop — read off
      # the built package. Left unpinned by request.
      name = "mousam";
      package = pkgs.mousam;
      ids = [ "io.github.amit9838.mousam.desktop" ];
      pin = false;
      browser = false;
      probeDesktop = [ "io.github.amit9838.mousam.desktop" "mousam.desktop" "mousam_mousam.desktop" ];
      probeCommands = [ "mousam" ];
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
    chromium = true;                      # Electron (lib/vscode/chrome_100_percent.pak)
    probeDesktop = [ "code.desktop" "visual-studio-code.desktop" "code_code.desktop" "com.visualstudio.code.desktop" ];
    probeCommands = [ "code" ];
  };

  # Services with no Linux desktop client at all, given a real launcher instead
  # of a bookmark. Notion publishes macOS and Windows builds only — nixpkgs'
  # `notion-app` is macOS-only (it installs Notion.app) and
  # `notion-app-enhanced` is a third-party notion-enhancer repackage, not a
  # Notion build — and YouTube Music has never had a desktop app. For both, the
  # vendor's web app IS the Linux client.
  #
  # `--app=` opens it in its own window with no tabs and no address bar, so it
  # behaves like an application and gets its own dash entry. It costs a .desktop
  # file and an icon (the browser is already installed) and uses the normal
  # browser profile, so logins persist and extensions still apply.
  #
  # Deliberately kept separate from desktopApps above: these install no package,
  # so they must not go through the probe/foreign-copy machinery.
  webAppDefs = [
    {
      name = "notion";
      title = "Notion";
      comment = "Write, plan, collaborate and get organised";
      url = "https://www.notion.so/";
      categories = "Office;ProjectManagement;";
      pin = true;
      # Notion's iOS app icon (front-static/logo-ios.png) is an opaque white
      # square by design — that is the white background behind the mark. This
      # one is the sticker-style logo with a real alpha channel (all four
      # corners verified at alpha 0) and a white outline, so it stays legible
      # against GNOME's dark dash instead of turning into a black-on-black blob.
      icon = pkgs.fetchurl {
        url = "https://www.notion.so/front-static/shared/icons/notion-app-icon-3d.png";
        hash = "sha256-ZlblCHqYTzPYoVO0N3+l1nBcB0N3sbOaHv+7d+OMwB4=";
      };
    }
    {
      name = "youtube-music";
      title = "YouTube Music";
      comment = "Stream music from YouTube Music";
      url = "https://music.youtube.com/";
      categories = "AudioVideo;Audio;Player;";
      pin = true;
      icon = pkgs.fetchurl {
        url = "https://music.youtube.com/img/favicon_144.png";
        hash = "sha256-EeHjawpnPC0RgpdCUJRpeVk8inVqRIUdD0UpcowaRwk=";
      };
    }
  ];

  # Apps the ROOT layer installs with apt rather than Nix. This module never
  # installs them and never touches their launcher — it only pins them, and
  # only when the .desktop file is genuinely on the machine, so it is a no-op
  # until then. install.sh runs the system layer BEFORE home-manager, so on a
  # clean provision Claude Desktop is already installed by the time the pin is
  # written; on a machine where it is switched off, nothing happens.
  #
  # `ids` are candidates rather than one known name: the file the .deb ships is
  # not something this module controls. If none of them match, the script falls
  # back to finding a system entry whose Exec runs `command`.
  # The .desktop names Brave's .deb has shipped. Shared by the pin below and by
  # set_default_browser, which resolves whichever one this machine actually has.
  braveSystemIds = [ "brave-browser.desktop" "brave.desktop" "com.brave.Browser.desktop" ];

  systemPins = [
    {
      name = "claude-desktop";
      command = "claude-desktop";
      ids = [ "claude-desktop.desktop" "Claude.desktop" "com.anthropic.Claude.desktop" "com.anthropic.claude.desktop" "anthropic-claude.desktop" ];
    }
  ] ++ lib.optional cfg.systemBrowser {
    # Brave from Brave's apt repo (system/78-brave.sh). Pinned through this
    # list rather than desktopApps because Nix does not own the package —
    # the whole point is that apt, not flake.lock, decides its version.
    name = "brave";
    command = "brave-browser";
    ids = braveSystemIds;
  };

  # Chromium-based apps the ROOT layer installed (apt/.deb), which therefore own
  # their own .desktop file in /usr/share where Nix cannot rewrite it. These get
  # modules.apps.chromiumFlags through an override written into XDG_DATA_HOME at
  # activation — see chromium_flag_overrides in apps-setup.
  #
  # TO ADD A FUTURE ELECTRON APP: one entry here (apt-installed) or
  # `chromium = true;` in desktopApps above (Nix-installed). Nothing else.
  #
  # Every one of these was confirmed to be Electron by finding its app.asar
  # rather than assumed from the vendor — OBS Studio, for one, bundles Chromium
  # (CEF, for browser sources) while being a Qt app whose windows this would do
  # nothing for, so "ships Chromium" is not the same question.
  #
  # `wmClass` is set only where the vendor's entry omits StartupWMClass and the
  # dash needs it to bind the window to this launcher; empty means leave it out.
  systemChromiumApps = [
    {
      name = "claude-desktop";           # /usr/lib/claude-desktop/resources/app.asar
      command = "claude-desktop";
      ids = [ "claude-desktop.desktop" "Claude.desktop" "com.anthropic.Claude.desktop" "com.anthropic.claude.desktop" "anthropic-claude.desktop" ];
      wmClass = "";
    }
    {
      name = "open-whispr";              # /opt/OpenWhispr/resources/app.asar
      command = "open-whispr";
      ids = [ "open-whispr.desktop" "openwhispr.desktop" "OpenWhispr.desktop" ];
      wmClass = "";
    }
    {
      name = "curseforge";               # /opt/CurseForge/resources/app.asar
      command = "curseforge";
      ids = [ "curseforge.desktop" "CurseForge.desktop" ];
      wmClass = "";
    }
  ] ++ lib.optional cfg.systemBrowser {
    # The apt Brave. Same treatment as the Electron apps above — it is the same
    # engine and the same problem: a .deb owns the launcher.
    name = "brave";
    command = "brave-browser";
    ids = braveSystemIds;
    # Brave's own entry declares no StartupWMClass and its main window reports
    # app_id "brave-browser"; without this the dash can fall back to a generic
    # icon for the window our override now owns.
    wmClass = "brave-browser";
  };

  # Apps listed in modules.apps.skip are dropped entirely: no package, no
  # desktop entry, no pin, never the default browser. setup.sh fills this in
  # automatically for anything it finds already installed outside Nix
  # (./setup.sh --sync-apps-skip), and you can add names by hand.
  # lib.unique because with systemBrowser on, "brave" is both a desktopApps
  # entry (dropped below) and a systemPins entry, and listing it twice in the
  # warning would be noise.
  knownNames = lib.unique (map (a: a.name) (desktopApps ++ [ vscodeApp ])
    ++ map (a: a.name) webAppDefs
    ++ map (a: a.name) systemPins);
  unknownSkips = lib.filter (n: !(lib.elem n knownNames)) cfg.skip;

  # With Brave from apt, the nixpkgs copy is dropped entirely: two browsers
  # would fight over the default handler and put two icons in the dash. Keyed
  # off the `browser` flag rather than the name, so it holds for any browser.
  installableApps =
    if cfg.systemBrowser then lib.filter (a: !(a.browser or false)) desktopApps
    else desktopApps;

  selected = lib.warnIf (unknownSkips != [ ])
    "modules.apps.skip: unknown app name(s) ${lib.concatStringsSep ", " unknownSkips} (known: ${lib.concatStringsSep ", " knownNames})"
    (lib.filter (a: !(lib.elem a.name cfg.skip)) installableApps);

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

    ${lib.optionalString ((app.chromium or false) && chromiumFlagsFor app != [ ]) ''
      # modules.apps.chromiumFlags for a Chromium-based app (`chromium = true`),
      # inserted right after the program so a trailing %U/%F field code stays
      # last, where the spec wants it. EVERY Exec= is rewritten, not just the
      # first: Desktop Actions ("New Window", VS Code's "New Empty Window") have
      # their own, and a switch missing from those is the "it works in some
      # windows but not others" trap.
      #
      # Only NIX-installed apps come through here. Anything installed by apt
      # owns a .desktop file in /usr/share that Nix cannot rewrite, so
      # apps-setup overrides those at activation instead.
      sed -i -E 's|^(Exec=[^[:space:]]+)|\1 ${chromiumFlagsStrFor app}|' entry.desktop
    ''}

    ${lib.optionalString (app.chromium or false) ''
      # Chromium never claims GNOME's xdg-activation token, so its startup
      # sequence only retires on timeout — which parks the ShellApp in STARTING
      # and makes the dash icon ignore clicks. See the StartupNotify note in
      # chromium_flag_override for what it does and does not fix.
      # Deliberately NOT gated on chromiumFlags: the stall has nothing to do with
      # the switches, and emptying the flag list must not bring it back.
      sed -i 's|^StartupNotify=true$|StartupNotify=false|' entry.desktop
    ''}

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

  # With Brave from apt the launcher belongs to the .deb, so its id is resolved
  # at run time (see set_default_browser) instead of being named here.
  browserId = if browserApp == null then "" else builtins.head browserApp.ids;

  # Only ever used to ask "did the machine already have this from apt/snap?".
  # The apt Brave is dome's own install, so it is deliberately NOT foreign.
  browserName =
    if cfg.systemBrowser then "brave"
    else if browserApp == null then "" else browserApp.name;

  browserBin =
    if cfg.systemBrowser then "/usr/bin/brave-browser"
    else if browserApp == null then null
    else "${browserApp.package}/bin/${browserApp.package.meta.mainProgram or browserApp.name}";

  # The app_id Chromium builds for an --app window is prefixed with the browser's
  # PRODUCT name, NOT the basename of the binary that launched it. Both `brave`
  # (nixpkgs) and `brave-browser` (the .deb) emit `brave-<host>…`, verified with
  # WAYLAND_DEBUG=1 launching /usr/bin/brave-browser:
  #   set_app_id("brave-music.youtube.com__-Default")
  # Deriving the prefix from the binary basename produced `brave-browser-…` under
  # the apt install, so StartupWMClass never matched: the web app showed its own
  # icon only while Brave was already running (GNOME bound the fast-appearing
  # window via startup-notification) and fell back to a generic cog on a cold
  # launch. browserName already resolves to the product name ("brave") for both
  # installs — reuse it so the class matches the real app_id.
  browserWmPrefix = browserName;

  # What $BROWSER points at — a wrapper, NOT the browser binary directly.
  #
  # Tools that honor $BROWSER (gh, git web--browse, xdg-open, python's
  # webbrowser) exec it as a child of the calling shell, so it inherits the
  # terminal's stdout/stderr. Chromium/Brave logs to stderr for the entire life
  # of the process — IPH_* education hints, the sharing service, sync GetUpdates
  # network errors — and none of it is suppressible upstream (they are
  # unconditional ERROR-level logs, not gated by any flag or pref). Point
  # $BROWSER straight at the binary and all of that lands in the shell, and
  # keeps landing for as long as the browser runs.
  #
  # setsid -f starts it in a new session with no controlling terminal and its
  # own /dev/null fds, so nothing it ever writes reaches the shell, and control
  # returns immediately. GUI launches are unaffected: they go through the
  # .desktop entry, which GNOME already starts detached.
  browserOpener =
    if browserBin == null then null
    else pkgs.writeShellScript "dome-browser" ''
      exec ${pkgs.util-linux}/bin/setsid -f "${browserBin}" ${chromiumFlagsStr} "$@" </dev/null >/dev/null 2>&1
    '';

  # The app that owns mailto: — same idea as browserApp, read with `or false`
  # because only the mail client sets the flag.
  mailerApp = lib.findFirst (a: a.mailer or false) null patched;
  mailerId = if mailerApp == null then "" else builtins.head mailerApp.ids;
  mailerName = if mailerApp == null then "" else mailerApp.name;

  # GNOME identifies a window by its Wayland app_id and matches that against
  # StartupWMClass to decide which launcher (and therefore which icon) it
  # belongs to. Chromium IGNORES --class on Wayland — it is an X11 flag — and
  # derives the id from the URL instead, so any hand-picked StartupWMClass
  # fails to match and the window falls back to a generic cog icon.
  #
  # Captured off the wire with WAYLAND_DEBUG=1 rather than guessed:
  #   set_app_id("brave-www.notion.so__-Default")
  #
  # Shape: <browser>-<host>_<path, with / rewritten to _>-<profile>. The bare
  # "https://host/" case therefore ends in a double underscore. The trailing
  # segment is the browser PROFILE directory name, so this holds for the
  # default profile; a second Brave profile would need its own value.
  webAppWmClass = app:
    let
      noScheme = lib.removePrefix "https://" (lib.removePrefix "http://" app.url);
      parts = builtins.match "([^/]+)(/.*)" noScheme;
      host = if parts == null then noScheme else builtins.elemAt parts 0;
      path = if parts == null then "/" else builtins.elemAt parts 1;
      appName = builtins.replaceStrings [ "/" ] [ "_" ] "${host}_${path}";
    in app.wmClass or "${browserWmPrefix}-${appName}-Default";

  # One launcher per web app.
  #
  # --class is kept even though Wayland ignores it: it is what sets WM_CLASS
  # under X11, so the same entry still matches correctly in an X11 session.
  #
  # Icon points straight at the fetched file in the store rather than a copy:
  # it is already an immutable absolute path, which is exactly what the GNOME
  # session needs (it cannot resolve themed icon names from the Nix profile).
  #
  # --start-maximized because an --app= window has no saved geometry the first
  # time it opens, so Chromium falls back to a small default. It keys saved
  # placement off the first label of the host (music.youtube.com -> "music",
  # www.notion.so -> "www"), and both entries in this profile were created with
  # no bounds at all, which is exactly the "why does it open tiny" symptom.
  # StartupNotify is false below for the same reason it is forced off for every
  # other Chromium launcher here — see the note in chromium_flag_override. A web
  # app IS a Brave --app window, so it parks the dash icon identically.
  #
  # No --ozone-platform here, deliberately. X11 would end the spinning cursor,
  # but a web app must stay on Wayland to keep its own identity: Wayland sets
  # app_id PER WINDOW, so Brave can label an --app window
  # brave-<host>__-Default even while it shares one process with the browser.
  # X11's WM_CLASS is per PROCESS, fixed by whichever Brave started first, so
  # every web app would collapse into the browser's dash icon (and --class is
  # ignored on handoff — measured). See the research doc.
  webAppEntry = app: pkgs.writeTextDir "share/applications/${app.name}.desktop" ''
    [Desktop Entry]
    Type=Application
    Version=1.5
    Name=${app.title}
    Comment=${app.comment}
    Exec=${builtins.toString browserBin}${chromiumFlagsSuffix} --app=${app.url} --class=${app.name} --start-maximized
    Icon=${app.icon}
    Terminal=false
    StartupNotify=false
    StartupWMClass=${webAppWmClass app}
    Categories=${app.categories}
  '';

  # No browser means no way to open a web app, so they drop out entirely rather
  # than installing a launcher whose Exec points at nothing. That happens only
  # when the browser is held back via appsSkip (e.g. the machine already has
  # its own Brave from apt).
  webApps =
    if browserBin == null then [ ]
    else map (a: a // { id = "${a.name}.desktop"; dir = webAppEntry a; })
      (lib.filter (a: !(lib.elem a.name cfg.skip)) webAppDefs);

  # "name:id" for everything that wants a dash pin, packaged apps and web apps
  # alike. The name half lets the pin be dropped when the machine already
  # provides that app itself.
  pinPairs =
    map (a: "${a.name}:${builtins.head a.ids}") (lib.filter (a: a.pin) patched)
    ++ map (a: "${a.name}:${a.id}") (lib.filter (a: a.pin) webApps)
    # Ghostty belongs to modules/terminal.nix — it installs the package and the
    # .desktop entry, because a terminal must not depend on the optional desktop
    # apps bundle. Only the dash pin lives here, since this is where the GNOME
    # favourites are merged; with `apps` off the terminal is still installed and
    # in the app grid, just not pinned. lib.optional is lazy, so desktopId is
    # never read when the terminal module is disabled.
    ++ lib.optional config.modules.terminal.enable
         "ghostty:${config.modules.terminal.desktopId}";

  # "<command>:<candidate ids…>" for the apt-installed apps above. Resolved at
  # run time, because whether they exist depends on the root layer, not Nix.
  systemPinSpecs = map (a: "${a.command}:${lib.concatStringsSep " " a.ids}")
    (lib.filter (a: !(lib.elem a.name cfg.skip)) systemPins);

  # Default dash pins this module removes when it finds them. Firefox because
  # the apps bundle ships its own browser (Ubuntu 24.04 pins the Firefox snap as
  # firefox_firefox.desktop; the other names cover a deb/flatpak install of the
  # same browser). The App Store and Help entries because a provisioned machine
  # does not want them taking dash slots — each is listed under every id the
  # distro has shipped it as (24.04's App Center is a snap; earlier releases and
  # a deb install use org.gnome.Software; Help is yelp).
  unpinIds = [
    "firefox_firefox.desktop"
    "firefox.desktop"
    "firefox-esr.desktop"
    "org.mozilla.firefox.desktop"
    "snap-store_snap-store.desktop"
    "snap-store_ubuntu-software.desktop"
    "org.gnome.Software.desktop"
    "ubuntu-software.desktop"
    "yelp.desktop"
    "org.gnome.Yelp.desktop"
  ];

  # Canonical left-to-right dash order. Each entry is the set of .desktop ids
  # that could stand for one app — snap/deb/flatpak variants included — so the
  # sort matches whichever id the machine actually pinned. This only orders pins
  # that are already present (this module's own, plus whatever the machine
  # pinned itself); it never adds a pin. Files and the Text Editor are stock
  # GNOME favourites this module does not manage, listed here purely so they
  # sort to the front when present. Anything not named keeps its existing
  # relative order and sorts after everything that is named.
  rawById = name: lib.findFirst (a: a.name == name) null desktopApps;
  candidatesFor = name:
    let a = rawById name; in if a == null then [ ] else lib.unique (a.ids ++ a.probeDesktop);
  claudeIds = lib.concatMap (a: a.ids) (lib.filter (a: a.name == "claude-desktop") systemPins);
  dashOrder = [
    [ "org.gnome.Nautilus.desktop" "nautilus.desktop" "org.gnome.Nautilus" ]  # Files
    [ "org.gnome.TextEditor.desktop" "gnome-text-editor.desktop" ]            # Text Editor
    [ config.modules.terminal.desktopId ]                                     # Ghostty
    (candidatesFor "discord")
    (candidatesFor "thunderbird")
    (candidatesFor "joplin")
    [ "notion.desktop" ]
    claudeIds                                                                 # Claude Desktop
    [ "youtube-music.desktop" ]
    (lib.unique (braveSystemIds ++ candidatesFor "brave"))
  ];
  # One space-separated candidate list per slot, empty slots dropped. Passed to
  # the script as one shell arg per slot (see merge_dash_pins).
  dashOrderSpecs = map (lib.concatStringsSep " ") (lib.filter (g: g != [ ]) dashOrder);

  # Desktop state GNOME keeps in dconf/mimeapps.list — not expressible as Nix
  # files, so it is reconciled by a small idempotent script instead. Run by the
  # activation hook below and installed as ~/.local/bin/apps-setup so it can be
  # re-run by hand after a login.
  appsSetup = pkgs.writeShellScript "apps-setup" ''
    # apps-setup — desktop integration for dome's `apps` module.
    #
    #   1. make ${browserId} the default browser (mimeapps.list, via gio)
    #   2. make ${mailerId} the default mail client (same mechanism)
    #   3. merge the GNOME dash pins: add this module's apps, drop Firefox /
    #      App Store / Help, and reorder to the canonical dash order
    #
    # MERGE, not overwrite: anything you pinned yourself survives (it just sorts
    # after the named apps). Deliberately no
    # `set -e` — desktop glue is best-effort and must never fail a switch on a
    # machine without GNOME.
    set -o pipefail

    export PATH="${lib.makeBinPath [
      pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.glib pkgs.desktop-file-utils
    ]}:/usr/bin:/bin:''${PATH:-}"

    # Resolve the entries straight out of the store, so this works even when it
    # runs before ~/.local/share/applications has been linked.
    export XDG_DATA_DIRS="${lib.concatMapStringsSep ":" (d: "${d}/share") (lib.concatMap (a: a.entryDirs) patched ++ map (a: a.dir) webApps)}:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

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

    # Where the distro puts .desktop files for software it installed itself.
    SYS_APP_DIRS="/usr/share/applications /usr/local/share/applications /var/lib/snapd/desktop/applications /var/lib/flatpak/exports/share/applications"

    # Resolve the .desktop id of an app the ROOT layer installed (apt). The
    # filename is the .deb's choice, not ours, so the known candidates are
    # tried first and then any system entry whose Exec actually runs <command>
    # — a renamed entry still gets found instead of silently losing its pin.
    system_desktop_id() { # <command> <candidate id>...
      local cmd="$1" dir base f
      shift
      for dir in $SYS_APP_DIRS; do
        for base in "$@"; do
          [ -e "$dir/$base" ] && { printf '%s\n' "$base"; return 0; }
        done
      done
      for dir in $SYS_APP_DIRS; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.desktop; do
          [ -e "$f" ] || continue
          if grep -qE "^Exec=(.*/)?$cmd([[:space:]]|$)" "$f" 2>/dev/null; then
            basename "$f"
            return 0
          fi
        done
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
    # ── 0b. chromiumFlags on the launchers apt owns ──────────────────────────
    # modules.apps.chromiumFlags reaches Nix-installed apps by being baked into
    # the entries patchDesktop writes. Apps installed by apt own their .desktop
    # file in /usr/share, which Nix cannot rewrite and which apt would overwrite
    # anyway — so for those this writes an override of the SAME .desktop id into
    # XDG_DATA_HOME, which XDG resolves in preference to /usr/share.
    #
    # Regenerated FROM the system entry on every switch rather than kept as a
    # frozen copy. That is the whole reason it survives app upgrades: a new
    # version that adds a launcher action or a translation shows up here on the
    # next `make home` instead of being masked forever by a stale override —
    # the failure mode of hand-copying a .desktop file once.
    #
    # Every file written carries a marker comment on line 1 (legal before the
    # first group — checked with desktop-file-validate) carrying two things:
    #
    #   OVERRIDE_MARKER_ID  identifies the file as ours, so the sweep at the end
    #                       can tell "dome put this here" from a launcher written
    #                       by hand, and an app that is later uninstalled or
    #                       dropped from the list leaves no dead entry behind.
    #   a STAMP             hash of (system entry + flags), i.e. of the inputs
    #                       this file was generated from.
    #
    # The stamp is what makes it safe for ANOTHER module to own the same Exec
    # line afterwards. modules/gaming.nix legitimately prepends gamemoderun to
    # CurseForge's, running after this by design. Comparing file CONTENT would
    # then see "different" on every switch, rewrite the file, and drop
    # gamemoderun until gaming.nix's activation put it back — and `apps-setup`
    # run on its own (it is on PATH) would drop it with nothing to restore it.
    # Comparing the stamp asks the question that actually matters instead: have
    # the source entry or the flag list changed since this was generated? If
    # not, leave the file alone, whatever else has since been layered onto it.
    OVERRIDE_MARKER_ID='modules.apps.chromiumFlags'

    # <flags> <wmclass-or-empty> <command> <candidate id>...
    chromium_flag_override() {
      local flags="$1" wmclass="$2" cmd="$3"
      shift 3
      local id src dir dst tmp stamp

      id="$(system_desktop_id "$cmd" "$@" || true)"
      # Not installed (yet). install.sh runs the system layer first, so this is
      # the normal state only for apps the machine has switched off.
      [ -n "$id" ] || return 0
      dst="$HOME/.local/share/applications/$id"
      WANTED="$WANTED $id"

      src=""
      for dir in $SYS_APP_DIRS; do
        if [ -e "$dir/$id" ]; then src="$dir/$id"; break; fi
      done
      if [ -z "$src" ]; then
        warn "found the id $id but not the file — chromiumFlags not applied to $cmd"
        return 0
      fi

      # Hash of everything this file is generated FROM. Compared against the
      # stamp in the existing file below instead of comparing content, so a
      # later module's edit to the same Exec line survives — see the note on
      # OVERRIDE_MARKER_ID above.
      stamp="$(cat "$src" - <<< "$flags" | sha256sum | cut -c1-12)"
      if [ -f "$dst" ] &&
         [ "$(sed -n "1s/.*\[$OVERRIDE_MARKER_ID:\([0-9a-f]*\)\].*/\1/p" "$dst")" = "$stamp" ]; then
        UNCHANGED="$UNCHANGED $id"
        return 0
      fi

      tmp="$(mktemp)"
      # EVERY Exec=, not just the first: Desktop Actions ("New Window", "New
      # Incognito Window") have their own Exec lines, and a switch missing from
      # those is the "it works in some windows but not others" trap. Switches go
      # directly after the program so a trailing %U/%F field code stays last,
      # where the desktop-entry spec wants it.
      { printf '# dome: generated [%s:%s] — edits are overwritten by `make home`.\n' \
          "$OVERRIDE_MARKER_ID" "$stamp"
        sed -E "s|^(Exec=[^[:space:]]+)|\1 $flags|" "$src"
      } > "$tmp"

      # GNOME binds a window to its launcher by app_id. Where the vendor's entry
      # declares no StartupWMClass and we know the class, spell it out, or the
      # dash can fall back to a generic icon for the window this override now
      # owns. Inserted after the FIRST Exec=, which is always the one in
      # [Desktop Entry] — appending to the end of the file would land it inside
      # the last [Desktop Action] group, where it means nothing. `0,/^Exec=/`
      # bounds the substitution to that first line.
      if [ -n "$wmclass" ] && ! grep -q '^StartupWMClass=' "$tmp"; then
        sed -i -E "0,/^Exec=/ s|^(Exec=.*)$|\1\nStartupWMClass=$wmclass|" "$tmp"
      fi

      # StartupNotify=false, deliberately. Nothing to do with the switches above.
      #
      # This fixes ONE precise thing: the dash icon ignoring a click for the
      # first ~15s after launch. Asking for startup notification puts the
      # ShellApp into SHELL_APP_STATE_STARTING, and Dash to Panel only offers
      # its minimise/activate behaviour once state == RUNNING (appIcons.js), so
      # until the sequence retires, clicking the icon does nothing at all —
      # against a Brave window that has been on screen since ~300ms.
      #
      # It does NOT stop the spinning cursor, and it was a mistake to think it
      # would. Verified with gnome-shell's own Eval: with this false the app
      # reaches state=RUNNING with its window bound 2ms after window-created,
      # and the busy cursor still runs its full course. That cursor has a
      # separate cause this repo cannot fix from a .desktop file — Brave orphans
      # xdg-activation tokens and mutter shows META_CURSOR_BUSY until they time
      # out. docs/research/2026-07-24-brave-gnome-startup-spinner.md has the
      # measurements, and the reason X11 is not the answer.
      sed -i 's|^StartupNotify=true$|StartupNotify=false|' "$tmp"

      install -Dm644 "$tmp" "$dst"
      rm -f "$tmp"
      log "chromiumFlags written to $id"
      CHANGED="$CHANGED $id"
    }

    # Remove overrides we previously wrote that nothing asks for any more — the
    # app was uninstalled, dropped from systemChromiumApps, or chromiumFlags was
    # emptied. Keyed off the marker, so a launcher the user wrote by hand (or
    # one home-manager owns, which is a symlink and never carries the marker) is
    # never touched.
    chromium_flag_sweep() {
      local f base
      for f in "$HOME/.local/share/applications"/*.desktop; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        head -n1 "$f" 2>/dev/null | grep -qF "[$OVERRIDE_MARKER_ID:" || continue
        base="$(basename "$f")"
        case " $WANTED " in *" $base "*) continue ;; esac
        log "removing stale chromiumFlags override: $base"
        rm -f "$f"
        CHANGED="$CHANGED $base"
      done
    }

    chromium_flag_overrides() {
      WANTED="" CHANGED="" UNCHANGED=""

      # Flags are passed PER APP, not from one shared variable: an app may drop
      # individual switches with chromiumFlagsExclude (see chromiumFlagsFor).
      # An app whose exclusions empty the list is omitted entirely, so it is
      # swept rather than given an override that changes nothing.
      ${lib.concatMapStringsSep "\n      "
        (a: ''chromium_flag_override ${lib.escapeShellArg (chromiumFlagsStrFor a)} ${lib.escapeShellArg (a.wmClass or "")} ${lib.escapeShellArg a.command} ${lib.escapeShellArgs a.ids}'')
        (lib.filter (a: chromiumFlagsFor a != [ ]) systemChromiumApps)}
      chromium_flag_sweep

      if [ -n "$CHANGED" ]; then
        log "  fully quit and reopen those apps to pick the switches up"
      elif [ -n "$UNCHANGED" ]; then
        log "chromiumFlags already on:$UNCHANGED"
      fi
    }

    # ── 1. default browser ───────────────────────────────────────────────────
    set_default_browser() {
      local id="${browserId}" mimeapps type
      ${lib.optionalString cfg.systemBrowser ''
        # Brave came from apt, so the .desktop name is the .deb's choice.
        # Resolve it the same way the system pins do.
        id="$(system_desktop_id brave-browser ${lib.escapeShellArgs braveSystemIds} || true)"
        if [ -z "$id" ]; then
          warn "Brave (apt) is not installed yet, so the default browser was left alone"
          return 0
        fi
      ''}
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

    # ── 2. default mail client ───────────────────────────────────────────────
    # mailto: is the one that matters (every "email us" link on the web); the
    # other two make .eml files and mid: links open in it as well. Left alone
    # if the machine already has its own copy — the same rule as the browser.
    set_default_mail_client() {
      local id="${mailerId}" mimeapps type
      [ -n "$id" ] || return 0
      if is_foreign ${lib.escapeShellArg mailerName}; then return 0; fi
      mimeapps="''${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
      if grep -qE "^x-scheme-handler/mailto=$id(;|$)" "$mimeapps" 2>/dev/null; then
        log "default mail client is already $id"
        return 0
      fi
      for type in x-scheme-handler/mailto message/rfc822 x-scheme-handler/mid; do
        gio_ mime "$type" "$id" >/dev/null 2>&1 || warn "could not set $type -> $id"
      done
      log "default mail client set to $id"
    }

    # ── 3. dash pins ─────────────────────────────────────────────────────────
    merge_dash_pins() {
      local raw cleaned joined="" entry pair name id
      local spec sys_cmd sys_ids sys_id ospec cand
      local -a current=() merged=() pins=() ordered=()
      local -a unpins=(${lib.escapeShellArgs unpinIds})
      # One arg per slot; each is a space-separated candidate-id list.
      local -a order_specs=(${lib.concatMapStringsSep " " lib.escapeShellArg dashOrderSpecs})

      # "name:id" pairs so a pin can be dropped by app name when the machine
      # already provides that app itself.
      for pair in ${lib.concatMapStringsSep " " lib.escapeShellArg pinPairs}; do
        name="''${pair%%:*}"
        is_foreign "$name" || pins+=("''${pair#*:}")
      done

      # Apps the root layer installed with apt. Absent = not pinned, which is
      # the normal state until the system layer has run.
      for spec in ${lib.concatMapStringsSep " " lib.escapeShellArg systemPinSpecs}; do
        sys_cmd="''${spec%%:*}"
        sys_ids="''${spec#*:}"
        # shellcheck disable=SC2086  # sys_ids is a space-separated candidate list
        if sys_id="$(system_desktop_id "$sys_cmd" $sys_ids)"; then
          in_list "$sys_id" ''${pins[@]+"''${pins[@]}"} || pins+=("$sys_id")
        else
          log "not installed yet, so not pinned: $sys_cmd"
        fi
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

      # Keep every current pin except the ones we drop (Firefox, App Store,
      # Help), then add this module's pins. Ordering is not decided here — the
      # reorder pass below imposes the canonical dash order, so a dropped
      # browser no longer needs its slot reused for the new one.
      for entry in ''${current[@]+"''${current[@]}"}; do
        [ -n "$entry" ] || continue
        in_list "$entry" ''${unpins[@]+"''${unpins[@]}"} && continue
        merged+=("$entry")
      done

      for id in ''${pins[@]+"''${pins[@]}"}; do
        in_list "$id" ''${merged[@]+"''${merged[@]}"} || merged+=("$id")
      done

      # Impose the canonical order: first emit the named apps that are present,
      # in order; then append everything else in its existing relative order.
      for ospec in ''${order_specs[@]+"''${order_specs[@]}"}; do
        for entry in ''${merged[@]+"''${merged[@]}"}; do
          # shellcheck disable=SC2086  # ospec is a space-separated candidate list
          for cand in $ospec; do
            [ "$entry" = "$cand" ] || continue
            in_list "$entry" ''${ordered[@]+"''${ordered[@]}"} || ordered+=("$entry")
            break
          done
        done
      done
      for entry in ''${merged[@]+"''${merged[@]}"}; do
        in_list "$entry" ''${ordered[@]+"''${ordered[@]}"} || ordered+=("$entry")
      done
      merged=(''${ordered[@]+"''${ordered[@]}"})

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

    # Before the cache refresh below, so the overrides it writes are in the MIME
    # cache in the same pass rather than only after the next switch.
    chromium_flag_overrides

    # Refresh the MIME cache so the new entries are picked up without a re-login.
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

    find_foreign
    set_default_browser
    set_default_mail_client
    merge_dash_pins
  '';
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = map (a: a.package) patched ++ extraPkgs;

      # Absolute-path desktop entries in XDG_DATA_HOME — see the header comment.
      # Web-app launchers land in the same place for the same reason: GNOME
      # only ever reads ~/.local/share/applications.
      xdg.dataFile = lib.listToAttrs (
        lib.concatMap entriesFor patched
        ++ map (a: {
          name = "applications/${a.id}";
          value.source = "${a.dir}/share/applications/${a.id}";
        }) webApps
      );

      # home.nix defaults this to firefox with mkDefault; the detaching opener
      # (see browserOpener above) wins when the apps module ships a browser. It
      # is an absolute /nix/store path, so it resolves everywhere — including
      # from the GNOME session, whose PATH has no Nix profile — and is
      # regenerated on every switch, so it cannot go stale. Falls back to plain
      # firefox when the browser is held back via appsSkip.
      home.sessionVariables.BROWSER =
        if browserOpener == null then lib.mkDefault "firefox" else "${browserOpener}";

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

      # Middle-click paste off in Gecko apps this repo does NOT build.
      #
      # geckoNoMiddleClickPaste handles the Thunderbird we install, through the
      # autoconfig file inside the package. That route is closed for anything
      # from snap, apt or flatpak: autoconfig lives in the install tree and
      # those are read-only images owned by the packager. Firefox here is the
      # Ubuntu snap, so it needs the other mechanism.
      #
      # user.js is that mechanism, and it is the only one that works whatever
      # the packaging: Gecko reads it on every start and applies it over
      # prefs.js. The cost is that it is per PROFILE — a profile created after
      # this runs is not covered until the next `make home`, which is exactly
      # why the Thunderbird we do build uses autoconfig instead.
      #
      # Each line carries the marker as a trailing comment, so removing the
      # block later is a one-line grep -v and hand-written prefs are untouched.
      home.activation.geckoNoMiddleClickPaste =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          _dome_marker="// dome:no-middle-click-paste"

          for _dome_profile in \
            "$HOME"/.mozilla/firefox/*/ \
            "$HOME"/snap/firefox/common/.mozilla/firefox/*/ ; do
            # The glob is literal when nothing matches, and these directories
            # also hold non-profiles ("Crash Reports", "Pending Pings"). A real
            # profile always has one of these two files.
            [ -d "$_dome_profile" ] || continue
            [ -f "$_dome_profile/prefs.js" ] || [ -f "$_dome_profile/times.json" ] || continue

            _dome_userjs="$_dome_profile/user.js"
            _dome_tmp="$(mktemp)"
            if [ -f "$_dome_userjs" ]; then
              # Drop our previous block; keep everything the user wrote.
              grep -v "$_dome_marker" "$_dome_userjs" > "$_dome_tmp" || true
            fi
            printf 'user_pref("middlemouse.paste", false);          %s\n' "$_dome_marker" >> "$_dome_tmp"
            printf 'user_pref("middlemouse.contentLoadURL", false); %s\n' "$_dome_marker" >> "$_dome_tmp"

            if ! cmp -s "$_dome_tmp" "$_dome_userjs"; then
              run cp "$_dome_tmp" "$_dome_userjs"
              echo "[apps] middle-click paste off in $_dome_profile"
            fi
            rm -f "$_dome_tmp"
          done
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
