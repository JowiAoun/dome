{ config, lib, pkgs, ... }:

let
  cfg = config.modules.ai;
  userConfig = import ../user-config.nix;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Core AI development tools
      claude-code         # Anthropic's official Claude CLI
    ];

    # Configuration files for AI tools
    home.file = {
      
      # Sample AI development scripts
      ".local/bin/ai-setup".text = ''
        #!/bin/bash
        echo "🤖 Setting up AI development environment..."
        
        # Claude Code is ready to use out of the box!
        echo "🔧 Claude Code installed and ready"
        
        # GitHub Copilot setup (optional)
        echo "💡 To enable GitHub Copilot: gh auth login"
        
        echo "✅ AI tools ready!"
        echo "💡 Try: claude for AI development assistance, gh copilot for code suggestions"
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

        ## GitHub Copilot CLI (gh is pre-installed)
        - Explain code: `gh copilot explain "your code here"`
        - Get suggestions: `gh copilot suggest "what you want to do"`
        - Shell commands: `gh copilot suggest -t shell "what you want to accomplish"`
        - Setup: `gh auth login` to enable Copilot features
      '';
    };

    # Make scripts executable
    home.activation.aiScripts = lib.hm.dag.entryAfter ["writeBoundary"] ''
      chmod +x ~/.local/bin/ai-setup
    '';
  };
}