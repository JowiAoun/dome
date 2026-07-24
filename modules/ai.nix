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
    #
    # nodejs only when modules.node is not already providing it. The skills CLI
    # below is an npm package that needs Node >= 22.20 to install AND to run,
    # and the module defaults do not line up: every host seed
    # (hosts/*/setup-defaults.env) ships MODULE_AI=true and MODULE_NODE=false,
    # so gating skills on the Node module would mean it silently does not exist
    # on a default machine. Same derivation node.nix installs, so when both
    # modules are on this is the identical store path — one Node in the profile,
    # no file collision (which is exactly what an explicitly different version
    # caused before; see the note in node.nix).
    home.packages = [ pkgs.xclip ]
      ++ lib.optional (!config.modules.node.enable) pkgs.nodejs_22;

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

      # Claude Code's status line: two rows, the first mirroring the shell
      # prompt (user, directory, git branch, styled from ~/.config/starship.toml
      # at runtime) and the second the session state — model, context remaining,
      # and the 5-hour and 7-day rate limit windows with their reset countdowns.
      #
      # Same reasoning as keybindings.json above: Claude Code only ever runs
      # this file, so a read-only store symlink is right. `statusLine` in
      # settings.json points at it (see claudeDefaults below).
      #
      # Kept as a real .sh rather than inlined as `text`: it is 230 lines of
      # bash whose every ''${...} would need escaping against Nix interpolation,
      # and as a file it stays runnable and `bash -n`-checkable on its own.
      ".claude/statusline-command.sh" = {
        source = ./ai-statusline.sh;
        executable = true;
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

        ## Claude Code keybindings and behaviour
        - `~/.claude/keybindings.json` is managed by modules/ai.nix
        - Shift+Enter inserts a newline (Ctrl+J still does too)
        - These values are declared by the module and re-applied on every
          `make home`, so changing one in `/config` lasts until then — edit
          modules/ai.nix to change it for good:
            - Theme: dark (also why a fresh machine never opens on the picker)
            - Show tips: off (`spinnerTipsEnabled`)
            - Use auto mode during plan: off (`useAutoModeDuringPlan`)
            - Copy on select: off — highlighting text in the fullscreen TUI no
              longer replaces your clipboard; copy with Ctrl+Shift+C
        - Everything else in those two files is passed through untouched: they
          are the app's own files, merged with jq rather than symlinked, because
          Claude Code writes to both constantly
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
    # Claude Code's "Copy on select": off.
    #
    # In the fullscreen TUI, Claude Code does its own mouse selection, and
    # highlighting anything copies it to the clipboard immediately — replacing
    # whatever was there. Ctrl+Shift+C (selection:copy) is the deliberate way to
    # copy, so the automatic one only ever costs you the clipboard.
    #
    # This is NOT a settings.json key, which is why it is not next to the
    # keybindings above: it is not in the published schema (125 properties,
    # checked) and lives in ~/.claude.json, the app's own 46 KB state file —
    # auth, project history, onboarding flags, caches. That file is written by
    # the app constantly, so managing it as a home.file symlink would make it
    # read-only and break Claude Code outright. Hence a merge instead.
    #
    # Seeded, not enforced: it writes the key only when absent, so toggling
    # "Copy on select" back on in /config sticks instead of being reverted by
    # the next `make home`.
    home.activation.claudeDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}:$PATH"

      # apply_json <file> <JSON object of values this module declares>
      #
      # `. + $want`: in jq the RIGHT operand wins on duplicate keys, so these
      # values are applied over whatever is in the file, and every other key it
      # holds is passed through untouched.
      #
      # Declared, not merely seeded — "write it only if the key is missing" was
      # the first attempt and it does not work here, because Claude Code
      # materialises its own defaults into settings.json as you use it. This
      # machine already had `useAutoModeDuringPlan: true` on disk, so a
      # seed-if-absent pass would have found the key present and left the
      # opposite of the requested value in place, silently. The cost is that
      # changing one of these in /config lasts until the next `make home`; the
      # module is the place to change it for good.
      #
      # Nothing is written when the file already agrees, which keeps this off
      # its mtime and stops jq reformatting a file the app is about to rewrite.
      apply_json() {
        local f="$1" d="$2" mode tmp
        mkdir -p "$(dirname "$f")"

        if [ ! -e "$f" ]; then
          printf '%s\n' "$d" | jq '.' > "$f" && chmod 600 "$f"
          return
        fi

        if ! jq -e . "$f" >/dev/null 2>&1; then
          echo "⚠️ $f is not readable JSON — leaving it untouched, set these in /config" >&2
          return
        fi

        if jq -e --argjson want "$d" \
             '. as $cur | all($want | to_entries[]; $cur[.key] == .value)' \
             "$f" >/dev/null 2>&1; then
          return                      # already exactly as declared
        fi

        # Temp file beside the target so the replacement is an atomic rename on
        # the same filesystem, and nothing is replaced unless jq produced
        # parseable, non-empty output: a botched merge into ~/.claude.json would
        # cost the session's credentials and history. The original mode is put
        # back because these two files do not agree on one (644 and 600).
        mode="$(stat -c '%a' "$f" 2>/dev/null || echo 600)"
        tmp="$(mktemp "$f.XXXXXX")"
        if jq --argjson want "$d" '. + $want' "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mv "$tmp" "$f" && chmod "$mode" "$f"
        else
          rm -f "$tmp"
          echo "⚠️ could not apply defaults to $f — set them in /config" >&2
        fi
      }

      if [ -n "''${DRY_RUN_CMD:-}" ]; then
        echo "(dry run) would apply Claude Code defaults to ~/.claude/settings.json and ~/.claude.json"
      else
        # All three are real settings.json keys, confirmed against the published
        # schema rather than guessed, and /config writes the same names:
        #
        # theme                 dark. Also what stops a fresh machine opening on
        #                       the theme picker.
        # spinnerTipsEnabled    /config calls this "Show tips" — the hints that
        #                       cycle in the spinner while Claude works. The
        #                       menu id is `tips`, the setting is this.
        # useAutoModeDuringPlan "Use auto mode during plan". Off: planning should
        #                       ask before running things rather than classify
        #                       them as safe on its own.
        #
        # statusLine            the two-row status line, whose script is the
        #                       home.file symlink above. Invoked through `bash`
        #                       rather than relying on the exec bit, so it still
        #                       works if the file is ever copied somewhere
        #                       without its mode.
        apply_json "$HOME/.claude/settings.json" '{
          "theme": "dark",
          "spinnerTipsEnabled": false,
          "useAutoModeDuringPlan": false,
          "statusLine": {
            "type": "command",
            "command": "bash ~/.claude/statusline-command.sh"
          }
        }'

        # copyOnSelect is NOT a settings.json key — it is absent from the schema
        # and lives in the app's state file, next to auth and history. Claude
        # Code may not have run yet on a fresh machine, and creating the file is
        # safe: it reads, merges and writes back, and onboarding keys off the
        # VALUE of hasCompletedOnboarding rather than the file existing.
        apply_json "$HOME/.claude.json" '{ "copyOnSelect": false }'
      fi
    '';

    # Node comes from modules.node when that is on and from home.packages above
    # when it is not, so this runs on every machine with the AI module — which
    # is the point: it is one of the tools this module exists to provide, not an
    # optional extra that quietly disappears when Node was not ticked.
    home.activation.installSkillsCli = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # AFTER linkGeneration, not writeBoundary: ~/.npmrc — which is what points
      # npm's global prefix at ~/.npm-global — is a linked file, and before that
      # step npm would fall back to the profile in the Nix store and fail on a
      # read-only filesystem. --prefix repeats it explicitly, which is also what
      # makes this work with modules.node off: node.nix writes that .npmrc, so
      # without it there would be no prefix at all. ~/.npm-global/bin is put on
      # PATH by home.nix's shell init, independently of the Node module.
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
    '';
  };
}
