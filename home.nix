{ config, pkgs, lib, userConfigPath ? null, ... }:

let
  # Use explicit path from flake, fallback to local path, then template
  userConfig = if userConfigPath != null && builtins.pathExists userConfigPath
    then import userConfigPath
    else if builtins.pathExists ./user-config.nix 
    then import ./user-config.nix 
    else import ./user-config.template.nix;
  isCodespaces = userConfig.environment.isCodespaces;
  isWSL = userConfig.environment.isWSL;

  # nixpkgs flattened the xorg.* set to lowercase top-level attrs and deprecated
  # the old path (warns on the post-2026 flake.lock). Prefer the new attr, fall
  # back to xorg.* on the previous pin — `x or y` short-circuits, so xorg.* is
  # never touched (no warning) when the new attr exists, yet it still evaluates on
  # the old pin. Lets this land without waiting on the flake.lock push.
  xlibs = {
    libxcb     = pkgs.libxcb     or pkgs.xorg.libxcb;
    libX11     = pkgs.libx11     or pkgs.xorg.libX11;
    libXext    = pkgs.libxext    or pkgs.xorg.libXext;
    libXrender = pkgs.libxrender or pkgs.xorg.libXrender;
    libXi      = pkgs.libxi      or pkgs.xorg.libXi;
    libSM      = pkgs.libsm      or pkgs.xorg.libSM;
    libICE     = pkgs.libice     or pkgs.xorg.libICE;
  };
in

{
  nixpkgs.config.allowUnfree = true;
  imports = [
    ./modules/default.nix
  ];
  
  # Environment-aware configuration (defaults that can be overridden)
  home.username = lib.mkDefault userConfig.environment.username;
  home.homeDirectory = lib.mkDefault userConfig.environment.homeDirectory;
  
  home.stateVersion = "24.05";

  # Don't print the "N unread news items" notice on every activation.
  news.display = "silent";

  # Module selections from user-config.nix
  modules = {
    python.enable = userConfig.modules.python;
    node.enable = userConfig.modules.node;
    java.enable = userConfig.modules.java;
    ai.enable = userConfig.modules.ai;
    cloud.enable = userConfig.modules.cloud;
    # `or false`: user-config.nix files written before the apps module existed
    # have no such attribute, and a missing attr is an evaluation error, not a
    # default. Never on Codespaces — it is a browser tab, not a desktop.
    apps.enable = (userConfig.modules.apps or false) && !isCodespaces;
    # Apps this machine already has from apt/snap/flatpak — detected by
    # ./setup.sh --sync-apps-skip, so Nix never installs a second copy.
    apps.skip = userConfig.appsSkip or [ ];
    # Brave from Brave's apt repo (system/78-brave.sh) instead of nixpkgs, so
    # the browser keeps getting security updates between flake bumps.
    apps.systemBrowser = userConfig.braveBrowser or false;

    # Ghostty. Deliberately NOT tied to `modules.apps`: that switch is for the
    # optional desktop-app bundle, and the terminal is the thing everything else
    # in this repo runs inside — including Claude Code, whose Shift+Enter needs a
    # terminal that can encode a modified Enter at all (modules/terminal.nix has
    # the measurements). So it follows only the "is there a desktop here?"
    # question: no on Codespaces, which is a browser tab, and no on WSL, where
    # the terminal belongs to Windows.
    terminal.enable = !isCodespaces && !isWSL;
  };

  # Pass user info to modules
  user = {
    name = userConfig.name;
    email = userConfig.email;
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
    fastfetch  # neofetch was removed from nixpkgs (unmaintained upstream)
    lazygit

    # Essential development tools (always installed)
    jq
    yq
    httpie
    age
    hyperfine
    bottom
    swi-prolog  # Prolog interpreter

    # Manim dependencies
    cairo         # Required by pycairo
    pango         # Required by manim for text rendering
    ffmpeg        # Required by manim for video encoding
    pkg-config    # Helps pip find system libraries
    xlibs.libxcb  # XCB headers for cairo
    harfbuzz      # Text shaping (pango dependency)
    fribidi       # Bidirectional text (pango dependency)

    # C libraries for pip packages with binary dependencies (numpy, opencv, pytorch, etc.)
    stdenv.cc.cc.lib  # libstdc++
    zlib              # compression
    libGL             # OpenGL
    glib              # libgthread, GLib
    xlibs.libX11      # X11
    xlibs.libXext     # X11 extensions
    xlibs.libXrender  # X11 rendering
    xlibs.libXi       # X11 input
    xlibs.libSM       # X11 session management
    xlibs.libICE      # X11 ICE
    fontconfig        # font configuration
    freetype          # font rendering
    libxkbcommon      # keyboard
    dbus              # D-Bus
    nss               # network security
    nspr              # Netscape runtime
    expat             # XML parsing
    alsa-lib          # audio
  ] ++ lib.optionals (!isCodespaces) [
    # Additional tools for local environments only (avoid Codespaces conflicts)
    # The `docker` CLI deliberately does NOT live here: a client with no daemon
    # only ever prints "Cannot connect to the Docker daemon", and the daemon is
    # root-owned systemd territory. Docker Engine (dockerd + docker + the
    # compose/buildx plugins) is installed by system/60-docker.sh instead.
    # docker-compose stays because it is a standalone binary that works against
    # whatever daemon is reachable, including a remote or Docker Desktop one.
    docker-compose
    lazydocker  # TUI over the daemon: containers, logs, images

    unzip
    zip
    nmap
    netcat
    gnupg
    # NOT openssh: the Nix build has no GSSAPI support, so it warns on Ubuntu's
    # system-wide config — `Unsupported option "gssapiauthentication"` from
    # /etc/ssh/ssh_config line 53 — on every single ssh and git-over-ssh call.
    # It also shadowed /usr/bin/ssh for no benefit; openssh-client ships with
    # Ubuntu (10-apt-base.sh makes sure of it) and is the client the system's
    # own config, agent socket and CA paths are written for.
  ];

  programs.home-manager.enable = true;

  # GNOME desktop preferences that aren't tied to any one module. Written
  # through home-manager's dconf (a `dconf load`, straight into the dconf
  # database) — the same mechanism modules/desktop-shell.nix uses, and the one
  # that actually reaches GNOME Shell. It is NOT the gsettings/keyfile path that
  # modules/apps.nix has to route around; that only matters for keys that merge
  # with live user state (dash pins, default browser), not a static boolean.
  #
  # A harmless no-op where there is no GNOME session (WSL, Codespaces): with no
  # session bus at activation, home-manager simply skips the dconf write.
  dconf.settings = {
    # Silence the click GNOME plays on every volume up/down keypress.
    # input-feedback-sounds is exactly that beep — leaving event-sounds alone
    # keeps the rest of the desktop's notification sounds working.
    "org/gnome/desktop/sound".input-feedback-sounds = false;
  };

  programs.vscode = {
    # Off when VS Code is already installed from apt/snap/flatpak (detected by
    # ./setup.sh --sync-apps-skip): two VS Codes on one machine is exactly the
    # kind of duplicate the apps module exists to avoid. modules/apps.nix gives
    # this one a working app-grid entry.
    enable = !isWSL && !(builtins.elem "vscode" (userConfig.appsSkip or [ ]));
    profiles.default = {
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
  };

  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" "ignorespace" ];
    shellAliases = {
      ll = "ls -l";
      la = "ls -la";
      grep = "grep --color=auto";
      ".." = "cd ..";
      p = "cd ~/p";
      l = "lazygit";
      c = "claude --dangerously-skip-permissions";
      g = "gemini --model gemini-3-flash";
    };
    initExtra = ''
      # LD_LIBRARY_PATH for pip packages with binary dependencies (numpy, opencv, pytorch, etc.)
      export LD_LIBRARY_PATH="${lib.makeLibraryPath [
        pkgs.stdenv.cc.cc.lib  # libstdc++
        pkgs.zlib              # compression
        pkgs.libGL             # OpenGL
        pkgs.glib              # libgthread, GLib
        pkgs.cairo             # cairo graphics (manim)
        pkgs.pango             # text rendering (manim)
        xlibs.libX11           # X11
        xlibs.libXext          # X11 extensions
        xlibs.libXrender       # X11 rendering
        xlibs.libXi            # X11 input
        xlibs.libSM            # X11 session management
        xlibs.libICE           # X11 ICE
        pkgs.fontconfig        # font configuration
        pkgs.freetype          # font rendering
        pkgs.libxkbcommon      # keyboard
        pkgs.dbus              # D-Bus
        pkgs.nss               # network security
        pkgs.nspr              # Netscape runtime
        pkgs.expat             # XML parsing
        pkgs.alsa-lib          # audio
      ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      # PKG_CONFIG_PATH for pip packages that need to find system libraries
      export PKG_CONFIG_PATH="${pkgs.cairo.dev}/lib/pkgconfig:${pkgs.pango.dev}/lib/pkgconfig:${pkgs.glib.dev}/lib/pkgconfig:${pkgs.harfbuzz.dev}/lib/pkgconfig:${pkgs.freetype.dev}/lib/pkgconfig:${pkgs.fribidi.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

      # C_INCLUDE_PATH for headers needed during pip builds
      export C_INCLUDE_PATH="${xlibs.libxcb.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

      # Add npm global bin and ~/.local/bin to PATH for locally installed tools
      export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

      # Source Nix. A multi-user (daemon) install puts the profile under
      # /nix/var/nix/..., NOT ~/.nix-profile — the latter only exists for a
      # single-user install. Try the daemon path first so `nix` is on PATH in
      # interactive shells; Ubuntu's zsh does not source it system-wide.
      if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      elif [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi

      # Initialize nodenv if available (shims must come before nix paths)
      if command -v nodenv >/dev/null 2>&1; then
        export NODENV_ROOT="$HOME/.nodenv"
        export PATH="$NODENV_ROOT/shims:$NODENV_ROOT/bin:$PATH"
        eval "$(nodenv init - bash)"
      fi

      # Same as zsh: a new terminal that starts at $HOME lands in ~/p, while a
      # shell opened inside a project keeps its directory.
      if [[ $- == *i* && $PWD == "$HOME" && -d "$HOME/p" ]]; then cd "$HOME/p"; fi

      # Source ghcup environment for Haskell development
      [ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"
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
      theme = ""; # Disable oh-my-zsh theme to use Starship
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
      p = "cd ~/p";
      l = "lazygit";
      lg = "lazygit";
      c = "claude --dangerously-skip-permissions";
      g = "gemini --model gemini-3-flash";
    };

    initContent = ''
      # LD_LIBRARY_PATH for pip packages with binary dependencies (numpy, opencv, pytorch, etc.)
      export LD_LIBRARY_PATH="${lib.makeLibraryPath [
        pkgs.stdenv.cc.cc.lib  # libstdc++
        pkgs.zlib              # compression
        pkgs.libGL             # OpenGL
        pkgs.glib              # libgthread, GLib
        pkgs.cairo             # cairo graphics (manim)
        pkgs.pango             # text rendering (manim)
        xlibs.libX11           # X11
        xlibs.libXext          # X11 extensions
        xlibs.libXrender       # X11 rendering
        xlibs.libXi            # X11 input
        xlibs.libSM            # X11 session management
        xlibs.libICE           # X11 ICE
        pkgs.fontconfig        # font configuration
        pkgs.freetype          # font rendering
        pkgs.libxkbcommon      # keyboard
        pkgs.dbus              # D-Bus
        pkgs.nss               # network security
        pkgs.nspr              # Netscape runtime
        pkgs.expat             # XML parsing
        pkgs.alsa-lib          # audio
      ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      # PKG_CONFIG_PATH for pip packages that need to find system libraries
      export PKG_CONFIG_PATH="${pkgs.cairo.dev}/lib/pkgconfig:${pkgs.pango.dev}/lib/pkgconfig:${pkgs.glib.dev}/lib/pkgconfig:${pkgs.harfbuzz.dev}/lib/pkgconfig:${pkgs.freetype.dev}/lib/pkgconfig:${pkgs.fribidi.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

      # C_INCLUDE_PATH for headers needed during pip builds
      export C_INCLUDE_PATH="${xlibs.libxcb.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

      # Add npm global bin and ~/.local/bin to PATH for locally installed tools
      export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"


      # Source Nix. A multi-user (daemon) install puts the profile under
      # /nix/var/nix/..., NOT ~/.nix-profile — the latter only exists for a
      # single-user install. Try the daemon path first so `nix` is on PATH in
      # interactive shells; Ubuntu's zsh does not source it system-wide.
      if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      elif [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi

      # Initialize nodenv if available (shims must come before nix paths)
      if command -v nodenv >/dev/null 2>&1; then
        export NODENV_ROOT="$HOME/.nodenv"
        export PATH="$NODENV_ROOT/shims:$NODENV_ROOT/bin:$PATH"
        eval "$(nodenv init - zsh)"
      fi

      # Prompt: Starship owns it (programs.starship.enableZshIntegration, below).
      # Do NOT run `prompt <theme>` here — a zsh prompt theme loads after
      # Starship's init and clobbers it, dropping you onto a user@host theme
      # instead of the Starship "@ user … ❯" prompt that bash already shows.

      # Enable Vi mode
      bindkey -v

      # Better history search
      autoload -U up-line-or-beginning-search
      autoload -U down-line-or-beginning-search
      zle -N up-line-or-beginning-search
      zle -N down-line-or-beginning-search
      bindkey "^[[A" up-line-or-beginning-search
      bindkey "^[[B" down-line-or-beginning-search

      # A fresh interactive shell that starts at $HOME jumps to the projects
      # dir, so a new terminal (Ghostty, VS Code with no folder open, tmux)
      # lands in ~/p without a manual cd. A shell opened inside a project starts
      # in that folder — PWD is not $HOME — so it is left where it is.
      if [[ -o interactive && $PWD == $HOME && -d $HOME/p ]]; then cd "$HOME/p"; fi

      # Source ghcup environment for Haskell development (must be at the end)
      [ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"
    '';
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    settings = {
      # Main prompt configuration
      format = "$all$character";
      
      # Character configuration
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
        vicmd_symbol = "[❮](bold yellow)";
      };
      
      # Directory configuration
      directory = {
        truncation_length = 3;
        truncation_symbol = "…/";
        home_symbol = "~";
        truncate_to_repo = false;
        style = "bold cyan";
      };
      
      # Git branch configuration
      git_branch = {
        symbol = " ";
        style = "bold purple";
        format = "[$symbol$branch(:$remote_branch)]($style) ";
      };
      
      # Git status configuration (disabled - using lazygit instead)
      git_status = {
        disabled = true;
      };
      
      # Language/runtime configurations
      nodejs = {
        disabled = true;
      };
      
      python = {
        symbol = "🐍 ";
        style = "bold yellow";
        format = "[$symbol$pyenv_prefix($version )(\($virtualenv\) )]($style)";
        version_format = "v\${major}.\${minor}";
      };
      
      java = {
        disabled = true;
      };
      
      ruby = {
        disabled = true;
      };
      
      golang = {
        disabled = true;
      };
      
      rust = {
        disabled = true;
      };
      
      docker_context = {
        symbol = "🐳 ";
        style = "bold blue";
        format = "[$symbol$context]($style) ";
      };
      
      # Package version (disabled)
      package = {
        disabled = true;
      };
      
      # Command duration
      cmd_duration = {
        min_time = 2000;
        format = "⏱️  [$duration]($style) ";
        style = "yellow bold";
      };
      
      # Time (disabled - not dynamic)
      time = {
        disabled = true;
      };
      
      # Battery (for laptops)
      battery = {
        full_symbol = "🔋 ";
        charging_symbol = "🔌 ";
        discharging_symbol = "⚡ ";
        unknown_symbol = "❓ ";
        empty_symbol = "❗ ";
        format = "[$symbol$percentage]($style) ";
      };
      
      # Memory usage
      memory_usage = {
        disabled = true; # Enable if you want to see memory usage
        threshold = 70;
        format = "🐏 [\${ram}( | \${swap})]($style) ";
        style = "bold dimmed green";
      };
      
      # Username (always show instead of hostname)
      username = {
        style_user = "bold dimmed green";
        style_root = "red bold";
        format = "@ [$user]($style) ";
        disabled = false;
        show_always = true;
      };
      
      # Hostname (disabled - showing username instead)
      hostname = {
        disabled = true;
      };
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = userConfig.name;
      user.email = userConfig.email;
      init.defaultBranch = userConfig.gitDefaultBranch;
      core.editor = userConfig.gitEditor;
      pull.rebase = true;
      # Use SSH for every GitHub remote, even a repo cloned over HTTPS: this
      # rewrites https://github.com/ URLs to git@github.com: at operation time,
      # so push/pull authenticate with the SSH key instead of a Personal Access
      # Token. Makes SSH the default without having to reclone anything.
      url."git@github.com:".insteadOf = "https://github.com/";
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

  # $HOME is for the XDG dirs (Documents, Music, …) and dotfiles; code lives in
  # ~/p. Create both on every host: a WSL install ships with neither the XDG
  # user dirs nor a projects folder, and we want them there too. The shells
  # auto-cd a fresh terminal into ~/p (see programs.zsh / programs.bash above).
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };
  home.activation.projectsDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''run mkdir -p "$HOME/p"'';

  home.file = {
    # mkdesktop: turn a locally-installed binary or AppImage (something without
    # a .deb, so it ships no desktop entry) into a searchable GNOME app. Kept as
    # a real .sh — like ai-statusline.sh — so it stays bash -n-checkable and free
    # of Nix ${} escaping. Usage: `mkdesktop <exe> --name "…" [--wmclass …]`.
    ".local/bin/mkdesktop" = {
      source = ./modules/mkdesktop.sh;
      executable = true;
    };

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
    # mkDefault so modules/apps.nix can point this at Brave without a conflict.
    BROWSER = lib.mkDefault "firefox";
    # gnome-terminal (VTE) chooses the shell it spawns from $SHELL, NOT from the
    # passwd entry — so `chsh -s zsh` in the system layer sets the login shell but
    # new terminals still come up on bash (VTE reads $SHELL=/bin/bash). Export it
    # here so terminals — and anything that launches "$SHELL": tmux, vim's :sh,
    # editors — land on zsh.
    #
    # This MUST be the apt path /usr/bin/zsh, which apt registers in /etc/shells
    # as a valid login shell. Do NOT point it at a /nix/store zsh: a $SHELL that
    # is not in /etc/shells makes Wayland GDM eject the GNOME session the instant
    # you log in (straight to exit.target — the login loop we hit once already).
    SHELL = "/usr/bin/zsh";
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
        pagers = [
          { pager = "delta --dark --paging=never"; }
        ];
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