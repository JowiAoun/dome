{
  description = "Personal dotfiles configuration with Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # A second nixpkgs pin used ONLY for Ghostty (overlaid onto pkgs.ghostty
    # below). It tracks the same nixos-unstable channel but is locked on its own,
    # so `nix flake update nixpkgs-ghostty` bumps the terminal to the latest
    # release without churning every other package in the main pin. Ghostty moves
    # fast and its newer versions carry features this repo relies on (e.g. the GTK
    # performable-paste passthrough in 1.3.0 that makes Ctrl+V image paste reach
    # Claude Code), so it is kept deliberately current.
    nixpkgs-ghostty.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-ghostty, home-manager, ... }:
  let
    system = "x86_64-linux";
    # Take Ghostty from the newer pin; everything else stays on the main one.
    ghosttyOverlay = final: prev: {
      ghostty = (import nixpkgs-ghostty { inherit system; config.allowUnfree = true; }).ghostty;
    };
    pkgs = import nixpkgs { inherit system; config.allowUnfree = true; overlays = [ ghosttyOverlay ]; };

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

      # Aliases for backward compatibility. These take a literal username: under
      # the pure evaluation that `path:.#...` refs use, envUser is always "",
      # which makes home.username empty and the configuration fail to evaluate —
      # so the aliases only LOOKED supported.
      vscode = makeConfig "vscode";
      codespaces = makeConfig "codespace";
    };
  };
}
