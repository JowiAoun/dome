{ config, pkgs, ... }:

{
  imports = [
    ./modules
  ];
  home.username = "user";
  home.homeDirectory = "/home/user";
  
  home.stateVersion = "24.05";

  # Enable/disable development modules
  modules = {
    python.enable = true;   # Set to false to disable
    node.enable = true;     # Set to false to disable  
    java.enable = false;    # Set to true to enable
  };

  home.packages = with pkgs; [
    git
    curl
    wget
    htop
    tree
    vim
    tmux
    fzf
    ripgrep
    fd
    bat
    exa
    neofetch
  ];

  programs.home-manager.enable = true;

  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" "ignorespace" ];
    shellAliases = {
      ll = "ls -l";
      la = "ls -la";
      grep = "grep --color=auto";
      ".." = "cd ..";
    };
  };

  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "your.email@example.com";
    extraConfig = {
      init.defaultBranch = "main";
      core.editor = "vim";
      pull.rebase = true;
    };
  };

  programs.tmux = {
    enable = true;
    shortcut = "a";
    baseIndex = 1;
    newSession = true;
    escapeTime = 0;
    historyLimit = 50000;
    extraConfig = ''
      set -g mouse on
      bind-key v split-window -h
      bind-key s split-window -v
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R
    '';
  };

  home.file = {
    ".vimrc".text = ''
      set number
      set relativenumber
      set tabstop=2
      set shiftwidth=2
      set expandtab
      set autoindent
      set smartindent
      set hlsearch
      set incsearch
      set ignorecase
      set smartcase
      syntax on
      colorscheme default
    '';
  };

  home.sessionVariables = {
    EDITOR = "vim";
    BROWSER = "firefox";
  };
}