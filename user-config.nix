{
  # User configuration - populated by bootstrap.sh
  name = "John Doe";
  email = "john.doe@example.com";
  
  # Module selections - chosen during bootstrap
  modules = {
    python = false;
    node = true;
    java = false;
    ai = true;
  };
  
  # Environment detection - auto-detected
  environment = {
    isCodespaces = false;
    isWSL = false;
    username = "vscode";  # Will be auto-detected
    homeDirectory = "/home/vscode";  # Will be auto-detected
  };
  
  # Additional user preferences
  gitDefaultBranch = "main";
  gitEditor = "vim";
  
  # Development environment preferences
  preferredShell = "zsh";
  preferredEditor = "vim";
}