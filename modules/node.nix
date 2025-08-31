{ config, lib, pkgs, ... }:

let
  cfg = config.modules.node;
  userConfig = import ../user-config.nix;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      nodejs_20
      nodePackages.npm
      nodePackages.pnpm
      nodePackages.typescript
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
    };

    home.file.".npmrc".text = ''
      prefix=~/.npm-global
      init-author-name=${userConfig.name}
      init-author-email=${userConfig.email}
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
  };
}