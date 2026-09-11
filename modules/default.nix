{ lib, ... }:

{
  imports = [
    ./python.nix
    ./node.nix
    ./java.nix
    ./ai.nix
    ./cloud.nix
    ./apps.nix
    ./xournalpp.nix
    ./terminal.nix
    ./desktop-shell.nix
    ./gaming.nix
  ];

  options = {
    modules = {
      python.enable = lib.mkEnableOption "Python development environment";
      node.enable = lib.mkEnableOption "Node.js development environment";
      java.enable = lib.mkEnableOption "Java development environment";
      ai.enable = lib.mkEnableOption "AI development tools (Claude, Ollama, Copilot, etc.)";
      cloud.enable = lib.mkEnableOption "Cloud development tools (Terraform, Pulumi, AWS CLI, etc.)";

      # Deliberately NOT under `apps`. The terminal is what every other tool in
      # this repo runs inside, so it must not ride on the optional desktop-apps
      # bundle — modules/terminal.nix's header explains the reasoning in full.
      terminal = {
        enable = lib.mkEnableOption "Ghostty terminal emulator and its desktop integration";
        setDefault = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Make Ghostty this session's default terminal, by pointing
            `org.gnome.desktop.default-applications.terminal` at it. That is the
            key gnome-settings-daemon resolves Ctrl+Alt+T through, and the one
            Nautilus's "Open in Terminal" reads, so one setting covers both.

            Off leaves the desktop opening GNOME Terminal; Ghostty is still
            installed, pinned to the dash and in the app grid.
          '';
        };
        desktopId = lib.mkOption {
          type = lib.types.str;
          default = "com.mitchellh.ghostty.desktop";
          description = ''
            The .desktop file Ghostty ships, read off the built package rather
            than guessed. Single source of truth for the two modules that need
            it: terminal.nix installs the entry under this name, apps.nix pins
            that name to the GNOME dash.
          '';
        };
      };

      apps = {
        enable = lib.mkEnableOption "Desktop applications (Brave, Discord, draw.io) and their desktop integration";
        skip = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "brave" ];
          description = ''
            Apps this module must not install or touch, by name (brave,
            discord, drawio) — for software the machine already has from apt,
            snap or flatpak. A skipped app gets no package, no desktop entry,
            no dash pin, and is never made the default browser.

            `./setup.sh --sync-apps-skip` fills this in by detecting what is
            already installed; entries added by hand are kept.
          '';
        };
        chromiumFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "--enable-features=MiddelButtonClickAutoscroll,MiddleClickAutoscroll"
            "--blink-settings=middleClickPasteAllowed=false"
          ];
          example = [ ];
          description = ''
            Command-line switches added to every launch of every Chromium-based
            app — the browser (its own launcher, the web app launchers and
            $BROWSER) and every Electron app, whether it came from nixpkgs or
            from apt.

            Electron IS Chromium, so one list covers both. Apps opt in with
            `chromium = true;` in modules/apps.nix (Nix-installed) or by being
            listed in systemChromiumApps (apt-installed) — adding a future
            Electron app is one line in whichever list applies.

            The default turns on middle-click autoscroll: hold the scroll wheel
            down and move the mouse to pan, the way Windows does. Chromium
            ships the feature but leaves it OFF on Linux, where middle click
            pastes the primary selection instead, and it has no
            enterprise-policy key — so a switch is the only way to set it
            without editing live profile state.

            BOTH spellings are listed on purpose, and both were read off real
            binaries rather than taken from a support page:

              MiddelButtonClickAutoscroll  Brave's own, typo and all ("Middel").
                                           Enabling brave://flags#middle-button-
                                           autoscroll in a scratch profile makes
                                           Brave hand exactly this to its child
                                           processes.
              MiddleClickAutoscroll        upstream Chromium/Electron's, present
                                           in Electron binaries that have no
                                           trace of Brave's spelling.

            An unrecognised feature name is ignored rather than an error, so the
            pair is safe everywhere and keeps working if Brave fixes its typo.

            `--enable-features` is what Brave's own flag entry injects, and it
            works for Electron too. The `--enable-blink-features` form most
            guides give would very likely work as well: MiddleClickAutoscroll is
            a Blink runtime-enabled feature, `status: "test"`, carrying the
            comment "enabled by default on Windows only. The only part that's
            experimental is the support on other platforms" — which is the
            clearest statement of what this option works around.

            KNOWN LIMITATION, not fixable here. In an editable area a middle
            click also MOVES THE TEXT CARET to the click point, and no switch
            turns that off. Blink places the caret in
            SelectionController::HandleMousePressEvent, which
            MouseEventManager calls for every button with no gate, and
            middleClickPasteAllowed only suppresses the paste that follows —
            its own comment reads "we want to paste to where the caret was
            placed anyway". Nor can a page work around it: the caret placement
            and the autoscroll start (Node::DefaultEventHandler) are BOTH
            default behaviour of the same mousedown, so preventDefault() loses
            the scrolling along with the caret. Autoscroll in a text editor
            therefore comes with a moving caret, or not at all — drop
            `--enable-features` for that app via chromiumFlagsExclude to choose
            the latter.

            The SECOND switch is what makes the first one usable. Turning
            autoscroll on does not turn the Linux middle-click paste off —
            Chromium does both at once, so a middle click pans the page AND
            dumps the clipboard into whatever is under the cursor. Confirmed on
            this machine, and NOT fixable through GNOME: Chromium subscribes to
            `notify::gtk-enable-primary-paste` but pastes anyway with that
            setting already false.

            `middleClickPasteAllowed` is a Blink setting (initial value true, in
            third_party/blink/renderer/core/frame/settings.json5), and
            `--blink-settings=` is the switch that reads that exact table. It is
            per-app, so this does not touch middle-click paste anywhere else on
            the system — the terminal keeps it, which is what you want there.

            Caveat worth knowing: Chromium IGNORES an unknown --blink-settings
            key silently, with no warning even at ERROR level (checked by
            launching with a deliberately bogus key and capturing stderr). So a
            typo here fails quietly — verify the name against settings.json5,
            not against the absence of an error message.
          '';
        };
        systemBrowser = lib.mkOption {
          type = lib.types.bool;
          default = false;
          example = true;
          description = ''
            Brave comes from Brave's own apt repository (system/78-brave.sh)
            rather than from nixpkgs. Wired from `braveBrowser` in
            user-config.nix.

            A browser is the one package that must not be pinned: flake.lock
            freezes nixpkgs at its last bump, so a Nix Brave cannot get a
            security update until someone runs `make update`.

            With this on, the apps module installs no Brave package, pins the
            apt one through systemPins, and points the web app launchers and
            $BROWSER at /usr/bin/brave-browser.
          '';
        };
        extras = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "obsidian" "localsend" "vlc" ];
          description = ''
            Extra nixpkgs package names to install alongside the module's apps —
            a one-word way to add software without editing modules/apps.nix.
            An unknown name fails evaluation with a readable message.

            These get no patched .desktop entry, so a GUI extra only appears in
            the GNOME dash if its own entry already uses absolute paths; move it
            into `desktopApps` in modules/apps.nix if it does not.
          '';
        };
      };
    };
    
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "User's full name";
      };
      email = lib.mkOption {
        type = lib.types.str;
        description = "User's email address";
      };
    };
  };
}