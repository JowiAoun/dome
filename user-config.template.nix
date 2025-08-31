{
  # User configuration template - copied to user-config.nix by bootstrap.sh
  # DO NOT commit user-config.nix - it may contain personal information
  name = "Your Full Name";
  email = "your.email@example.com";
  
  # Module selections - chosen during bootstrap
  modules = {
    python = false;
    node = false;
    java = false;
    ai = true;
  };
  
  # Environment detection - auto-detected by bootstrap
  environment = {
    isCodespaces = false;
    isWSL = true;
    username = "jaoun";
    homeDirectory = "/home/jaoun";
  };
  
  # Additional user preferences
  gitDefaultBranch = "main";
  gitEditor = "vim";
  
  # Development environment preferences
  preferredShell = "zsh";
  preferredEditor = "vim";
}