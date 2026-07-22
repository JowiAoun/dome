{ config, lib, pkgs, ... }:

let
  cfg = config.modules.ai;
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
  };
}
