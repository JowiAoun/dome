{
  description = "Personal dotfiles configuration with Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

    # Legacy path only: username from the environment. Empty under pure
    # evaluation; kept until the username-keyed outputs below are retired.
    envUser = builtins.getEnv "USER";

    # Host-profile path (PLAN.md Phase G1): username/homeDirectory come from
    # user-config.nix (template fallback inside home.nix), so no environment
    # reads are needed. Select with: home-manager switch --flake .#<host>
    mkHome = host: home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ./home.nix
        (./hosts + "/${host}/default.nix")
        {
          _module.args.userConfigPath = ./user-config.nix;
        }
      ];
    };

    # Legacy constructor for the username-keyed outputs.
    makeConfig = username: home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ./home.nix
        {
          # Override username and home directory at runtime
          home.username = username;
          home.homeDirectory = if username == "codespace" then "/home/codespace" else "/home/${username}";

          # Pass user config explicitly to fix path resolution in flakes
          _module.args.userConfigPath = ./user-config.nix;
        }
      ];
    };
  in {
    homeConfigurations = {
      # Host-profile outputs — the modern path; add new machines as hosts/<name>.
      generic = mkHome "generic";
      zenbook-duo = mkHome "zenbook-duo";

      # Legacy username-keyed outputs (WSL/Codespaces back-compat).
      default = makeConfig (if envUser != "" then envUser else "user");
      user = makeConfig "user";
      jaoun = makeConfig "jaoun";
      codespace = makeConfig "codespace";

      # Alias for backward compatibility
      vscode = makeConfig envUser;
      codespaces = makeConfig envUser;
    };
  };
}
