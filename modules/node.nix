{ config, lib, pkgs, ... }:

let
  cfg = config.modules.node;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      nodejs_20
      nodePackages.npm
      nodePackages.yarn
      nodePackages.pnpm
      nodePackages.typescript
      nodePackages.ts-node
      nodePackages.eslint
      nodePackages.prettier
      nodePackages.nodemon
      nodePackages."@vue/cli"
      nodePackages.create-react-app
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
      ni = "npm install";
      ns = "npm start";
      nt = "npm test";
      nb = "npm run build";
      nd = "npm run dev";
      npx = "npx --yes";
      yi = "yarn install";
      ys = "yarn start";
      yt = "yarn test";
      yb = "yarn build";
      yd = "yarn dev";
    };
  };
}