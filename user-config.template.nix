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
    apps = false;    # Desktop apps (Brave, Discord, draw.io) + desktop integration
  };

  # Apps the machine already has from apt/snap/flatpak - the apps module leaves
  # these completely alone. Filled in by ./setup.sh --sync-apps-skip.
  appsSkip = [ ];

  # System-layer switches. These live outside `modules` because the root layer
  # (system/*.sh) reads them with sed, not Nix - they install things Nix cannot
  # provide on Ubuntu (a systemd daemon, a group, a .deb).
  dockerEngine = true;    # Docker Engine (CE) from Docker's apt repo: dockerd + docker + compose/buildx plugins
  dockerDesktop = false;  # Docker Desktop GUI: ~450 MB download, needs KVM

  # Machine name - applied to /etc/hostname, the GNOME "Device Name" and
  # /etc/hosts. Empty leaves whatever the machine is already called.
  hostName = "";

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