{ config, lib, pkgs, ... }:

let
  cfg = config.modules.ai;
  userConfig = import ../user-config.nix;
in
{
  config = lib.mkIf cfg.enable {
    # Gemini CLI installed via npm (for latest version 0.22.2)
    # Note: Removed pkgs.gemini-cli as we use npm version for latest updates
    home.packages = with pkgs; [
      # gemini-cli package removed - using npm installation for latest version
    ];

    # Note: Claude Code installed via official installer script (not in nixpkgs)

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
      # Claude Code installer script
      ".local/bin/install-claude" = {
        executable = true;
        text = ''
          #!/bin/bash
          echo "🤖 Installing Claude Code from official installer..."

          # Download and run the official Claude Code installer
          if curl -fsSL https://claude.ai/install.sh | bash; then
            echo "✅ Claude Code installed successfully!"
            echo "💡 You can now use 'claude' command in your terminal"
          else
            echo "❌ Failed to install Claude Code"
            echo "💡 Try running manually: curl -fsSL https://claude.ai/install.sh | bash"
            exit 1
          fi

          # Install Claude Code VS Code extension automatically
          if command -v code >/dev/null 2>&1; then
            echo "📦 Installing Claude Code VS Code extension..."
            code --install-extension anthropic.claude-code --force 2>/dev/null && {
              echo "✅ Claude Code VS Code extension installed!"
            } || {
              echo "⚠️  Extension installation failed. You can install it manually:"
              echo "   Extension ID: anthropic.claude-code"
              echo "   Or search for 'Claude Code for VSCode' by Anthropic"
            }
          else
            echo "💡 Install VS Code to get the Claude extension automatically"
          fi

          echo "✅ AI tools ready!"
          echo "💡 Try: claude for AI development assistance"
        '';
      };
      
      # Sample AI development scripts
      ".local/bin/ai-setup" = {
        executable = true;
        text = ''
          #!/bin/bash
          echo "🤖 Setting up AI development environment..."

          # Install Claude Code if not already installed
          if ! command -v claude >/dev/null 2>&1; then
            echo "📦 Installing Claude Code..."
            ~/.local/bin/install-claude
          else
            echo "🔧 Claude Code already installed and ready"
          fi

          # Gemini CLI is installed via npm for latest version
          if command -v gemini >/dev/null 2>&1; then
            echo "🔧 Gemini CLI ready (installed via npm)"
            echo "   Version: $(gemini --version 2>/dev/null || echo 'unknown')"
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
        - Perfect for pair programming and code assistance
        - Works out of the box with this installation!

        ## Gemini CLI
        - Interactive AI development assistant: `gemini` (alias: `g`)
        - Installed via npm - latest version (0.22.2+)
        - Open-source AI agent powered by Google Gemini
        - Free tier: 60 requests/min and 1,000 requests/day
        - Built-in tools: Google Search, file operations, shell commands
        - Update: npm install -g @google/gemini-cli@latest

        ## VS Code Integration
        - Extension automatically installed: anthropic.claude-code
        - VS Code will suggest the extension when opening projects
        - Use Claude directly in VS Code for code assistance
        - Seamless integration with your development workflow
        - If auto-install fails, manually install using ID: anthropic.claude-code
      '';
    };

    # Install Claude Code automatically (Gemini CLI is installed via Nix packages)
    home.activation.aiScripts = lib.hm.dag.entryAfter ["writeBoundary"] ''
      # Install Claude Code if not already present
      if ! command -v claude >/dev/null 2>&1; then
        echo "📦 Installing Claude Code automatically..."
        if [ -f ~/.local/bin/install-claude ]; then
          ~/.local/bin/install-claude || echo "⚠️ Claude Code installation failed, run ~/.local/bin/install-claude manually"
        fi
      else
        echo "✅ Claude Code already installed"
      fi

      echo "✅ AI tools configured"
    '';
  };
}