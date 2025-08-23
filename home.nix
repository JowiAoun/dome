{ config, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;
  imports = [
    ./modules
  ];
  home.username = "vscode";
  home.homeDirectory = "/home/vscode";
  
  home.stateVersion = "24.05";

  # Enable/disable development modules
  modules = {
    python.enable = true;   # Set to false to disable
    node.enable = false;    # Disabled to avoid Node.js version conflict in Codespaces
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
    neofetch
    lazygit
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
    initExtra = ''
      # Source Nix if available
      if [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi
    '';
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    
    history = {
      size = 10000;
      save = 10000;
      ignoreDups = true;
      ignoreSpace = true;
    };

    shellAliases = {
      ll = "ls -l";
      la = "ls -la";
      grep = "grep --color=auto";
      ".." = "cd ..";
      lg = "lazygit";
    };

    initContent = ''
      # Source Nix if available
      if [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi

      # Set prompt
      autoload -U promptinit; promptinit
      prompt adam1

      # Enable Vi mode
      bindkey -v
      
      # Better history search
      autoload -U up-line-or-beginning-search
      autoload -U down-line-or-beginning-search
      zle -N up-line-or-beginning-search
      zle -N down-line-or-beginning-search
      bindkey "^[[A" up-line-or-beginning-search
      bindkey "^[[B" down-line-or-beginning-search
    '';
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
    SHELL = "${pkgs.zsh}/bin/zsh";
  };

  programs.lazygit = {
    enable = true;
    settings = {
      gui = {
        theme = {
          lightTheme = false;
          activeBorderColor = ["cyan" "bold"];
          inactiveBorderColor = ["default"];
          selectedLineBgColor = ["blue"];
        };
        commitLength = 50;
        sidePanelWidth = 0.3333;
      };
      git = {
        paging = {
          colorArg = "always";
          pager = "delta --dark --paging=never";
        };
        commit = {
          signOff = false;
        };
        merging = {
          manualCommit = false;
          args = "";
        };
      };
      refresher = {
        refreshInterval = 10;
        fetchInterval = 60;
      };
    };
  };
}