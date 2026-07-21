{
  # User configuration template - copied to user-config.nix by bootstrap.sh
  # DO NOT commit user-config.nix - it may contain personal information
  name = "Jowi Aoun";
  email = "83415433+JowiAoun@users.noreply.github.com";
  
  # Module selections - chosen during bootstrap
  modules = {
    python = false;
    node = false;
    java = false;
    ai = true;
    cloud = true;
  };
  
  # Host profile - selects hosts/<name> for BOTH layers (Nix + system/):
  #   "generic"      any non-Duo machine (WSL, Codespaces, plain Linux)
  #   "zenbook-duo"  the ASUS Zenbook Duo (2024) UX8406MA laptop
  hostProfile = "generic";

  # Environment detection - auto-detected by bootstrap
  environment = {
    isCodespaces = false;
    isWSL = true;
    username = "user";
    homeDirectory = "/home/user";
  };
  
  # Additional user preferences
  gitDefaultBranch = "main";
  gitEditor = "vim";
  
  # Development environment preferences
  preferredShell = "zsh";
  preferredEditor = "vim";
}