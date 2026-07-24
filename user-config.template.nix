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
  claudeDesktop = true;   # Claude desktop app (Linux beta) from Anthropic's signed apt repo
  openWhispr = true;      # OpenWhispr voice-to-text dictation, from the vendor's GitHub
                          # release (.deb). x64 Linux only, and a ~1 GB install — the
                          # script refuses rather than filling a small disk.
  braveBrowser = true;    # Brave from Brave's signed apt repo, upgraded to the newest
                          # published build on every `sudo make system` instead of
                          # freezing at the flake pin
  braveManagedPolicy = true;  # Brave's settings as enterprise policy in /etc (survives
                              # updates, cannot drift): Leo, Wallet, Rewards, VPN, News
                              # and Web Discovery off. See system/79-brave-policy.sh.
  gameMode = false;       # Feral GameMode: /etc/gamemode.ini plus a CurseForge launcher
                          # that starts the game through gamemoderun. Moves the CPU
                          # governor to performance while a game is running (gamemode's
                          # own iGPU logic backs off again when the integrated GPU is the
                          # bottleneck, which it is on Meteor Lake).
                          # TRADEOFF: more heat, more fan, less battery while playing.
                          # See system/86-gamemode.sh and modules/gaming.nix.
  tpmAutoUnlock = false;  # Enroll the LUKS root into the TPM (Clevis, PCR 7) so boot
                          # skips the passphrase. Keeps the passphrase as a fallback.
                          # SECURITY TRADEOFF: anyone who powers the machine on reaches
                          # the login screen without the disk passphrase. Off by default;
                          # opt in deliberately. See system/96-tpm-unlock.sh.

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