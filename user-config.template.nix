{
  # User configuration template - copied to user-config.nix by bootstrap.sh
  # DO NOT commit user-config.nix - it contains personal information
  name = "Your Full Name";
  email = "your.email@example.com";
  
  # Module selections - chosen during bootstrap
  modules = {
    python = false;
    node = false;
    java = false;
    ai = true;  # AI tools enabled by default
  };
  
  # Environment detection - auto-detected by bootstrap
  environment = {
    isCodespaces = false;
    isWSL = false;
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