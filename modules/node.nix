{ config, lib, pkgs, ... }:

let
  cfg = config.modules.node;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      nodejs_20
      nodePackages.npm  
      nodePackages.pnpm
      nodePackages.typescript
      nodenv  # Node version manager similar to pyenv
    ];

    # VS Code extensions for Node.js development
    programs.vscode = lib.mkIf config.programs.vscode.enable {
      extensions = with pkgs.vscode-extensions; [
        dbaeumer.vscode-eslint
        esbenp.prettier-vscode
        bradlc.vscode-tailwindcss
        postman.postman-for-vscode
      ];
    };

    home.sessionVariables = {
      NODE_PATH = "$HOME/.npm-global/lib/node_modules:$NODE_PATH";
      PATH = "$HOME/.npm-global/bin:$PATH";
      NODENV_ROOT = "$HOME/.nodenv";
    };

    home.file.".npmrc".text = ''
      prefix=~/.npm-global
      init-author-name=${config.user.name}
      init-author-email=${config.user.email}
      save-exact=true
    '';

    programs.bash.shellAliases = lib.mkIf config.programs.bash.enable {
      pi = "pnpm install";
      ps = "pnpm start";
      pt = "pnpm test";
      pb = "pnpm build";
      pd = "pnpm dev";
      px = "pnpm dlx";
    };

    # Initialize nodenv in shell
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable ''
      # Initialize nodenv
      if command -v nodenv >/dev/null 2>&1; then
        export NODENV_ROOT="$HOME/.nodenv"
        export PATH="$NODENV_ROOT/bin:$PATH"
        eval "$(nodenv init - bash)"
      fi
      
      # Also keep nvm support for the existing ~/.nvm installation
      export NVM_DIR="$HOME/.nvm"
      if [ -s "$NVM_DIR/nvm.sh" ]; then
        source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
      fi
    '';

    programs.zsh.initExtra = lib.mkIf config.programs.zsh.enable ''
      # Initialize nodenv
      if command -v nodenv >/dev/null 2>&1; then
        export NODENV_ROOT="$HOME/.nodenv"
        export PATH="$NODENV_ROOT/bin:$PATH"
        eval "$(nodenv init - zsh)"
      fi
      
      # Also keep nvm support for the existing ~/.nvm installation
      export NVM_DIR="$HOME/.nvm"
      if [ -s "$NVM_DIR/nvm.sh" ]; then
        source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
      fi
    '';

    # Install node-build plugin for nodenv (provides `nodenv install` command)
    home.activation.nodenvPlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
      NODENV_ROOT="$HOME/.nodenv"
      NODE_BUILD_DIR="$NODENV_ROOT/plugins/node-build"

      if [ ! -d "$NODE_BUILD_DIR" ]; then
        echo "Installing node-build plugin for nodenv..."
        mkdir -p "$NODENV_ROOT/plugins"
        ${pkgs.git}/bin/git clone https://github.com/nodenv/node-build.git "$NODE_BUILD_DIR"
        echo "node-build plugin installed"
      fi
    '';
  };
}