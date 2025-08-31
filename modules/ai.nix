{ config, lib, pkgs, ... }:

let
  cfg = config.modules.ai;
  userConfig = import ../user-config.nix;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Core AI development tools
      claude-code
    ];

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
      
      # Sample AI development scripts
      ".local/bin/ai-setup".text = ''
        #!/bin/bash
        echo "🤖 Setting up AI development environment..."
        
        # Claude Code is ready to use out of the box!
        echo "🔧 Claude Code installed and ready"
        
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
      
      # AI development tips
      ".local/share/ai-tips.md".text = ''
        # AI Development Tips

        ## Claude Code
        - Interactive AI development assistant: `claude`
        - File editing, code review, debugging, and development tasks
        - Built by Anthropic, the makers of Claude
        - Perfect for pair programming and code assistance
        - Works out of the box with this installation!

        ## VS Code Integration
        - Extension automatically installed: anthropic.claude-code
        - VS Code will suggest the extension when opening projects
        - Use Claude directly in VS Code for code assistance  
        - Seamless integration with your development workflow
        - If auto-install fails, manually install using ID: anthropic.claude-code
      '';
    };

    # Make scripts executable and auto-install Claude Code extension
    home.activation.aiScripts = lib.hm.dag.entryAfter ["writeBoundary"] ''
      chmod +x ~/.local/bin/ai-setup
      
      # Auto-install Claude Code VS Code extension if VS Code is available
      if command -v code >/dev/null 2>&1; then
        echo "🤖 Auto-installing Claude Code VS Code extension..."
        code --install-extension anthropic.claude-code --force 2>/dev/null || true
        echo "✅ Claude Code extension installation attempted"
      fi
    '';
  };
}