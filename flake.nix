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
    pkgs = import nixpkgs { inherit system; };
  in {
    homeConfigurations = {
      vscode = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };

      codespaces = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home-codespaces.nix ];
      };

      default = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home-codespaces.nix ];
      };
    };
  };
}
