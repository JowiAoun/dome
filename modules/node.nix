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
    ];

    home.sessionVariables = {
      NODE_PATH = "$HOME/.npm-global/lib/node_modules:$NODE_PATH";
      PATH = "$HOME/.npm-global/bin:$PATH";
    };

    home.file.".npmrc".text = ''
      prefix=~/.npm-global
      init-author-name=Your Name
      init-author-email=your.email@example.com
      init-license=MIT
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