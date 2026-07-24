{ config, lib, pkgs, ... }:

let
  cfg = config.modules.ai;

  # Claude Code probes the clipboard on every paste, to see whether what you
  # pasted was an image. On Wayland it reaches for wl-clipboard, and that is
  # what makes an icon blink in the dash on each copy/paste.
  #
  # GNOME 46 does not implement wlr-data-control (no `data_control` global is
  # advertised), so wl-paste/wl-copy have no headless way to reach the
  # clipboard. They fall back to mapping a real — if 1x1 — toplevel purely to
  # receive a keyboard-focus serial. WAYLAND_DEBUG=1 wl-paste shows it:
  #
  #   -> xdg_toplevel@15.set_title("wl-clipboard")
  #   -> wl_surface@13.attach(wl_buffer@18, 0, 0)   # mapped => the dash draws it
  #      wl_keyboard@12.enter(...)                  # the serial it was after
  #   -> xdg_toplevel@15.destroy()                  # ~20ms later, gone
  #
  # It never calls set_app_id, so the shell cannot match it to a .desktop and
  # falls back to a generic placeholder icon — the flash. xclip does the same
  # job through Xwayland using a window it never maps, so nothing is drawn.
  #
  # These shims are put in front of Claude Code ONLY (see the shell hook
  # below), never installed into the profile: they cover just the flags Claude
  # Code passes, so they must not shadow the real wl-clipboard for anything
  # else on the system.
  clipboardShims = pkgs.symlinkJoin {
    name = "claude-clipboard-shims";
    paths = [
      (pkgs.writeShellScriptBin "wl-paste" ''
        # No X server to borrow means no xclip: a brief window beats a broken
        # clipboard, so hand back to the real tool.
        if [ -z "''${DISPLAY:-}" ]; then
          for real in /usr/bin/wl-paste /run/current-system/sw/bin/wl-paste; do
            [ -x "$real" ] && exec "$real" "$@"
          done
          exit 1
        fi

        # Asked for a specific type, xclip hands back the default selection
        # rather than failing when that type is not on offer -- so a request for
        # image/png against a text clipboard would answer with the text. Real
        # wl-paste exits non-zero there, and callers rely on that, so check
        # TARGETS first and only then ask for the type.
        paste_type() {
          ${pkgs.xclip}/bin/xclip -selection clipboard -t TARGETS -o 2>/dev/null \
            | grep -qxF "$1" || exit 1
          exec ${pkgs.xclip}/bin/xclip -selection clipboard -t "$1" -o
        }

        case "''${1:-}" in
          -l|--list-types)
            exec ${pkgs.xclip}/bin/xclip -selection clipboard -t TARGETS -o
            ;;
          -t|--type)
            paste_type "''${2:-}"
            ;;
          --type=*)
            paste_type "''${1#--type=}"
            ;;
          *)
            exec ${pkgs.xclip}/bin/xclip -selection clipboard -o
            ;;
        esac
      '')
      (pkgs.writeShellScriptBin "wl-copy" ''
        if [ -z "''${DISPLAY:-}" ]; then
          for real in /usr/bin/wl-copy /run/current-system/sw/bin/wl-copy; do
            [ -x "$real" ] && exec "$real" "$@"
          done
          exit 1
        fi

        sel=clipboard
        type=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -p|--primary)  sel=primary ;;
            -t|--type)     type="''${2:-}"; shift ;;
            --type=*)      type="''${1#--type=}" ;;
            -c|--clear)    exec ${pkgs.xclip}/bin/xclip -selection "$sel" -i /dev/null ;;
            # Flags that only shape wl-copy's own process behaviour; xclip
            # already backgrounds itself to serve the selection.
            -n|--trim-newline|-f|--foreground|-o|--paste-once) : ;;
            --)            shift; break ;;
            -*)            : ;;  # unknown flag: ignore, never treat it as text
            *)             break ;;
          esac
          shift
        done

        run_xclip() {
          if [ -n "$type" ]; then
            ${pkgs.xclip}/bin/xclip -selection "$sel" -t "$type" -i
          else
            ${pkgs.xclip}/bin/xclip -selection "$sel" -i
          fi
        }

        # Anything left over is the text to copy, joined like wl-copy does.
        # With no arguments the payload comes from stdin, which run_xclip
        # inherits untouched.
        if [ $# -gt 0 ]; then
          printf '%s' "$*" | run_xclip
        else
          run_xclip
        fi
      '')
    ];
  };

  # Prepend the shims for Claude Code alone. `command` bypasses this function,
  # so the real binary is still resolved from PATH (~/.local/bin/claude) and
  # keeps self-updating; nothing is shadowed permanently.
  claudeWrapper = ''
    claude() {
      PATH="${clipboardShims}/bin:$PATH" command claude "$@"
    }
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Claude Code is installed from Anthropic's official installer (see the
    # activation hook below), NOT from nixpkgs. The installer always fetches the
    # newest release and the installed binary self-updates thereafter, so you
    # stay on the current model line (Opus 4.8 / Fable 5 …). The nixpkgs build is
    # frozen at the flake pin and lives in the read-only store, so it can neither
    # be the latest nor update itself — that is what shipped the stale v2.0.76
    # (Opus 4.5) build. The target here is Ubuntu (glibc/FHS), where the official
    # binary runs as-is without Nix's autoPatchelf.
    #
    # Gemini CLI is installed via npm (for the latest 0.22.x) by `ai-setup`.

    # Ubuntu ships neither xclip nor wl-clipboard by default — on this machine
    # they only exist because `pass` recommends them. Without one of the two,
    # Claude Code has no clipboard helper at all and pasting a screenshot into
    # it silently does nothing, so install the one that draws no window.
    home.packages = [ pkgs.xclip ];

    # Keep wl-clipboard's throwaway toplevel out of the dash — Claude Code only.
    programs.zsh.initContent = lib.mkIf config.programs.zsh.enable claudeWrapper;
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable claudeWrapper;

    # VS Code workspace recommendations for Claude Code extension
    home.file.".vscode/extensions.json" = lib.mkIf config.programs.vscode.enable {
      text = builtins.toJSON {
        recommendations = [
          "anthropic.claude-code"  # Official Claude Code for VSCode extension
        ];
      };
    };

    # Configuration files for AI tools
    home.file = {
      # Claude Code's key map. Only the bindings that differ from the defaults
      # belong here — the file is merged over them, not a replacement, so
      # everything unlisted keeps working (Ctrl+J still inserts a newline).
      #
      # shift+enter -> chat:newline is why modules/terminal.nix exists. In GNOME
      # Terminal it could never fire: VTE 0.76 encodes Shift+Enter and Enter
      # identically, as a bare CR, so no application can distinguish them. In
      # Ghostty the Kitty keyboard protocol sends CSI 13;2u and Claude Code
      # decodes it — its own /terminal-setup names the same short list of
      # terminals that "support Shift+Enter natively" (iTerm2, WezTerm, Ghostty,
      # Kitty, Warp, Windows Terminal).
      #
      # Managed as a symlink into the store, so the file is read-only: Claude
      # Code reads keybindings.json and never writes it. Its settings.json is
      # deliberately NOT managed here — that one the app rewrites itself
      # (model, effort, /config), and a read-only symlink would break it.
      ".claude/keybindings.json".text = builtins.toJSON {
        "$schema" = "https://www.schemastore.org/claude-code-keybindings.json";
        "$docs" = "https://code.claude.com/docs/en/keybindings";
        bindings = [
          {
            context = "Chat";
            bindings = { "shift+enter" = "chat:newline"; };
          }
        ];
      };

      # AI helper: install/refresh Claude Code (latest) and Gemini (npm).
      ".local/bin/ai-setup" = {
        executable = true;
        text = ''
          #!/bin/bash
          echo "🤖 Setting up AI development environment..."

          # Claude Code — install the latest from the official installer if missing.
          if command -v claude >/dev/null 2>&1; then
            echo "🔧 Claude Code ready — $(claude --version 2>/dev/null || echo installed); it keeps itself up to date"
          else
            echo "📦 Installing the latest Claude Code..."
            curl -fsSL https://claude.ai/install.sh | bash \
              || echo "⚠️  Install failed; retry: curl -fsSL https://claude.ai/install.sh | bash"
          fi

          # Gemini CLI — latest via npm.
          if command -v gemini >/dev/null 2>&1; then
            echo "🔧 Gemini CLI ready — $(gemini --version 2>/dev/null || echo installed)"
          else
            echo "📦 Installing Gemini CLI..."
            npm install -g @google/gemini-cli@latest
          fi

          # skills (vercel-labs) — always to the latest, unlike the activation
          # hook, which only installs it when missing. This is the command to
          # run when a newer release is wanted.
          if command -v npm >/dev/null 2>&1; then
            echo "📦 Installing/refreshing the skills CLI..."
            npm install -g skills@latest \
              && echo "🔧 skills ready — $(skills --version 2>/dev/null || echo installed)" \
              || echo "⚠️  skills install failed; retry: npm install -g skills@latest"
          else
            echo "⚠️  npm not found — set modules.node = true; to get the skills CLI"
          fi
        '';
      };

      # AI development tips
      ".local/share/ai-tips.md".text = ''
        # AI Development Tips

        ## Claude Code
        - Interactive AI development assistant: `claude` (alias: `c`)
        - File editing, code review, debugging, and development tasks
        - Built by Anthropic, the makers of Claude
        - Installed from the official installer (https://claude.ai/install.sh) so
          you always get the newest release; the binary then self-updates
        - Reinstall or repair anytime with: `ai-setup`

        ## Skills CLI (vercel-labs/skills)
        - The open agent-skills ecosystem: reusable instruction sets that plug
          into Claude Code, Cursor, OpenCode and ~70 other agents
        - Installed globally, so it is `skills ...` rather than `npx skills ...`
          — no re-download on every invocation, and it works offline
        - `skills find` browse/search, `skills add <source>` install,
          `skills ls`, `skills update`, `skills rm`, `skills init` (new SKILL.md)
        - Scope: project (`./.claude/skills/`) by default, `-g` for
          `~/.claude/skills/` — so a skill added with `-g` is available to Claude
          Code in every repo on this machine
        - Update: run `ai-setup`, or `npm install -g skills@latest`
        - Telemetry is on by default; `DISABLE_TELEMETRY=1` or the cross-tool
          `DO_NOT_TRACK=1` turns it off

        ## Claude Code keybindings
        - `~/.claude/keybindings.json` is managed by modules/ai.nix
        - Shift+Enter inserts a newline (Ctrl+J still does too)
        - It needs a terminal that can encode a modified Enter — that is what
          Ghostty is for; GNOME Terminal cannot, and there Ctrl+J is the only
          newline key that works

        ## Gemini CLI
        - Interactive AI development assistant: `gemini` (alias: `g`)
        - Installed via npm - latest version (0.22.2+)
        - Open-source AI agent powered by Google Gemini
        - Free tier: 60 requests/min and 1,000 requests/day
        - Built-in tools: Google Search, file operations, shell commands
        - Install/update: run `ai-setup`, or `npm install -g @google/gemini-cli@latest`

        ## VS Code Integration
        - Extension recommended: anthropic.claude-code
        - VS Code will suggest the extension when opening projects
        - Use Claude directly in VS Code for code assistance
        - If it doesn't prompt, install manually using ID: anthropic.claude-code
      '';
    };

    # Install the latest Claude Code during home-manager activation — which is
    # exactly what `./setup.sh` -> `./install.sh` runs — so no extra commands are
    # needed. Earlier attempts silently failed because activation runs with a
    # minimal PATH that lacks curl; put curl (and common tools) on PATH here.
    # Only install when `claude` is missing (an existing copy self-updates), judge
    # success by the binary actually appearing rather than the pipe's exit code,
    # and never fail the whole switch on a network error.
    home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.curl pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.gnutar pkgs.gzip ]}:$PATH"
      # Already installed (it self-updates) → do nothing, quietly.
      if ! { command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; }; then
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "(dry run) would install the latest Claude Code from https://claude.ai/install.sh"
        else
          echo "📦 Installing the latest Claude Code (official installer)…"
          curl -fsSL https://claude.ai/install.sh | bash || true
          if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
            echo "✅ Claude Code installed to ~/.local/bin (on PATH via the shell config)"
          else
            echo "⚠️ Claude Code install did not complete (network?). Re-run later: curl -fsSL https://claude.ai/install.sh | bash" >&2
          fi
        fi
      fi
    '';

    # `skills` — the vercel-labs agent-skills CLI.
    #
    # Upstream's README documents `npx skills add …` and offers no global
    # install, but the published package declares `bin: { skills, add-skill }`,
    # so `npm install -g skills` yields exactly the same CLI as a real command:
    # no package resolution and download on every invocation, it works offline,
    # and `skills` is a name that tab-completes.
    #
    # Installed only when missing, like Claude Code above — `ai-setup` is what
    # pulls a newer one. It moves fast (1.5.20 shipped the day before this was
    # written), so pinning a version here would be wrong within a week.
    #
    # Rides on modules.node because it IS an npm package: its engines field asks
    # for Node >= 22.20.0 and node.nix installs nodejs_22. With the Node module
    # off there is no npm to install it with, and referencing one here would
    # drag a second Node into the closure of machines that asked for neither.
    home.activation.installSkillsCli = lib.mkIf config.modules.node.enable (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        # AFTER linkGeneration, not writeBoundary: ~/.npmrc — which is what
        # points npm's global prefix at ~/.npm-global — is a linked file, and
        # before that step npm would fall back to the profile in the Nix store
        # and fail on a read-only filesystem. --prefix repeats it explicitly so
        # this keeps working even if that file moves.
        export PATH="${lib.makeBinPath [ pkgs.nodejs_22 pkgs.coreutils ]}:$PATH"
        if [ ! -x "$HOME/.npm-global/bin/skills" ]; then
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "(dry run) would install the skills CLI (npm install -g skills)"
          else
            echo "📦 Installing the skills CLI (vercel-labs)…"
            if npm install -g --prefix "$HOME/.npm-global" skills@latest >/dev/null 2>&1; then
              echo "✅ skills installed to ~/.npm-global/bin (on PATH via the shell config) — try 'skills find'"
            else
              echo "⚠️ skills install did not complete (network?). Re-run later: npm install -g skills@latest" >&2
            fi
          fi
        fi
      ''
    );
  };
}
