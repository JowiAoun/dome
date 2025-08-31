{ config, pkgs, lib, ... }:

let
  userConfig = import ./user-config.nix;
  isCodespaces = userConfig.environment.isCodespaces;
in

{
  nixpkgs.config.allowUnfree = true;
  imports = [
    ./modules/default.nix
  ];
  
  # Environment-aware configuration
  home.username = userConfig.environment.username;
  home.homeDirectory = userConfig.environment.homeDirectory;
  
  home.stateVersion = "24.05";

  # Module selections from user-config.nix
  modules = {
    python.enable = userConfig.modules.python;
    node.enable = userConfig.modules.node;
    java.enable = userConfig.modules.java;
    ai.enable = userConfig.modules.ai;
  };

  # Environment-aware package selection
  home.packages = with pkgs; [
    # Core tools (always installed)
    git
    gh
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
    
    # Essential development tools (always installed)
    jq
    yq
    httpie
    age
    hyperfine
    bottom
  ] ++ lib.optionals (!isCodespaces) [
    # Additional tools for local environments only (avoid Codespaces conflicts)
    docker
    docker-compose
    unzip
    zip
    wslu
    nmap
    netcat
    gnupg
    openssh
  ];

  programs.home-manager.enable = true;

  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      # Theme
      enkia.tokyo-night
      
      # GitHub & Remote development
      github.codespaces
      
      # Nix language support
      jnoortheen.nix-ide
      
      # Essential extensions
      redhat.vscode-yaml

      # Utils
      wayou.vscode-todo-highlight
      gruntfuggly.todo-tree
    ] ++ lib.optionals (!isCodespaces) [
      # Remote development extensions (local environments only)
      ms-vscode-remote.remote-wsl
      ms-vscode-remote.remote-ssh
    ];
    
    userSettings = {
      "workbench.colorTheme" = "Tokyo Night";
      "editor.fontFamily" = "'Fira Code', 'Droid Sans Mono', monospace";
      "editor.fontLigatures" = true;
      "editor.fontSize" = 14;
      "editor.tabSize" = 2;
      "editor.insertSpaces" = true;
      "editor.formatOnSave" = true;
      "editor.minimap.enabled" = false;
      "workbench.startupEditor" = "none";
      "explorer.confirmDelete" = false;
      "git.enableSmartCommit" = true;
      "git.confirmSync" = false;
      "terminal.integrated.fontSize" = 13;
    };
  };

  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" "ignorespace" ];
    shellAliases = {
      ll = "ls -l";
      la = "ls -la";
      grep = "grep --color=auto";
      ".." = "cd ..";
      l = "lazygit";
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
    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "docker" "kubectl" "npm" "node" "python" "vscode" ];
      theme = "robbyrussell";
    };
    
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
      l = "lazygit";
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
    userName = userConfig.name;
    userEmail = userConfig.email;
    extraConfig = {
      init.defaultBranch = userConfig.gitDefaultBranch;
      core.editor = userConfig.gitEditor;
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
    EDITOR = userConfig.preferredEditor;
    BROWSER = "firefox";
    SHELL = "${pkgs.${userConfig.preferredShell}}/bin/${userConfig.preferredShell}";
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