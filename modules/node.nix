{ config, lib, pkgs, ... }:

let
  cfg = config.modules.node;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Single Node version only. An explicit different version (was nodejs_20)
      # collided with the v22 that the tools pull in, on shared files such as
      # share/bash-completion/completions/node.bash. npm ships inside nodejs, so
      # it is not listed separately (that would also collide on bin/npm).
      # Use TOP-LEVEL pnpm/typescript, not nodePackages.* — that set has been
      # removed in newer nixpkgs and would break on a future flake update.
      nodejs_22
      pnpm
      typescript
      nodenv  # Node version manager similar to pyenv
    ];

    # VS Code extensions for Node.js development
    programs.vscode = lib.mkIf config.programs.vscode.enable {
      profiles.default.extensions = with pkgs.vscode-extensions; [
        dbaeumer.vscode-eslint
        esbenp.prettier-vscode
        bradlc.vscode-tailwindcss
        # postman.postman-for-vscode: not in the pinned nixpkgs; note that
        # home-manager forces these lists even when the module is disabled,
        # so a missing attr here breaks EVERY host with vscode enabled
      ];
    };

    home.sessionVariables = {
      # Guarded append (see the PYTHONPATH note in python.nix): no trailing colon
      # when NODE_PATH is unset.
      NODE_PATH = "$HOME/.npm-global/lib/node_modules\${NODE_PATH:+:$NODE_PATH}";
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
      # NOT `ps`: that shadows procps ps in every interactive bash shell, so
      # typing `ps` to look at processes runs this project's start script
      # instead. (It also cost an hour of debugging once — INSTALL-LOG Round 7
      # blamed a "stray" ~/.bashrc alias that was in fact generated right here.)
      pst = "pnpm start";
      pt = "pnpm test";
      pb = "pnpm build";
      pd = "pnpm dev";
      px = "pnpm dlx";
    };

    # nodenv init lives in home.nix (single source of truth, so its shims land
    # ahead of the Nix profile). Here the node module only wires up nvm.
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable ''
      # Also keep nvm support for the existing ~/.nvm installation
      export NVM_DIR="$HOME/.nvm"
      if [ -s "$NVM_DIR/nvm.sh" ]; then
        source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
      fi
    '';

    programs.zsh.initContent = lib.mkIf config.programs.zsh.enable ''
      # Also keep nvm support for the existing ~/.nvm installation
      export NVM_DIR="$HOME/.nvm"
      if [ -s "$NVM_DIR/nvm.sh" ]; then
        source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
      fi
    '';

    # Install node-build plugin for nodenv (provides `nodenv install` command).
    # DRY_RUN_CMD-aware and non-fatal on network errors — see the matching note
    # in modules/python.nix.
    home.activation.nodenvPlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
      NODENV_ROOT="$HOME/.nodenv"
      NODE_BUILD_DIR="$NODENV_ROOT/plugins/node-build"

      if [ ! -d "$NODE_BUILD_DIR" ]; then
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "(dry run) would clone node-build into $NODE_BUILD_DIR"
        else
          echo "Installing node-build plugin for nodenv..."
          mkdir -p "$NODENV_ROOT/plugins"
          if ${pkgs.git}/bin/git clone https://github.com/nodenv/node-build.git "$NODE_BUILD_DIR"; then
            echo "node-build plugin installed"
          else
            echo "⚠️ node-build clone failed (network?) — re-run 'make home' later" >&2
          fi
        fi
      fi
    '';
  };
}