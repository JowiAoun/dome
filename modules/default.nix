{ lib, ... }:

{
  imports = [
    ./python.nix
    ./node.nix
    ./java.nix
    ./ai.nix
    ./cloud.nix
    ./apps.nix
  ];

  options = {
    modules = {
      python.enable = lib.mkEnableOption "Python development environment";
      node.enable = lib.mkEnableOption "Node.js development environment";
      java.enable = lib.mkEnableOption "Java development environment";
      ai.enable = lib.mkEnableOption "AI development tools (Claude, Ollama, Copilot, etc.)";
      cloud.enable = lib.mkEnableOption "Cloud development tools (Terraform, Pulumi, AWS CLI, etc.)";

      apps = {
        enable = lib.mkEnableOption "Desktop applications (Brave, Discord, draw.io) and their desktop integration";
        skip = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "brave" ];
          description = ''
            Apps this module must not install or touch, by name (brave,
            discord, drawio) — for software the machine already has from apt,
            snap or flatpak. A skipped app gets no package, no desktop entry,
            no dash pin, and is never made the default browser.

            `./setup.sh --sync-apps-skip` fills this in by detecting what is
            already installed; entries added by hand are kept.
          '';
        };
        extras = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "obsidian" "localsend" "vlc" ];
          description = ''
            Extra nixpkgs package names to install alongside the module's apps —
            a one-word way to add software without editing modules/apps.nix.
            An unknown name fails evaluation with a readable message.

            These get no patched .desktop entry, so a GUI extra only appears in
            the GNOME dash if its own entry already uses absolute paths; move it
            into `desktopApps` in modules/apps.nix if it does not.
          '';
        };
      };
    };
    
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "User's full name";
      };
      email = lib.mkOption {
        type = lib.types.str;
        description = "User's email address";
      };
    };
  };
}