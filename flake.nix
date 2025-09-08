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
    
    # Get current user from environment or fallback
    username = builtins.getEnv "USER";
    
    # Create configuration that works for any user
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
      # Fallback configurations
      default = makeConfig (if username != "" then username else "user");
      user = makeConfig "user";
      jaoun = makeConfig "jaoun";
      codespace = makeConfig "codespace";
      
      # Alias for backward compatibility
      vscode = makeConfig username;
      codespaces = makeConfig username;
    };
  };
}
