# Host profile: a headless home server on Ubuntu Server 24.04 that you reach
# over SSH. It gets the same shell as every other machine (zsh, Starship, git,
# tmux, vim, lazygit, lazydocker) and nothing that needs a screen.
#
# User layer only. That machine has its own setup for Docker, GRUB, the kernel
# and power, so system/00-preflight.sh refuses to run the system layer there.
# Install it with:
#
#   sudo apt install -y zsh
#   ./setup.sh --defaults homeserver
#   ./bootstrap.sh
#   chsh -s /usr/bin/zsh
{ lib, ... }:

{
  # Nothing here can open a window. home.nix turns Ghostty and VS Code on for
  # every machine that is not WSL or Codespaces, and the desktop apps follow
  # the apps module, so all three go off. mkForce, because home.nix sets them
  # without a priority.
  modules.terminal.enable = lib.mkForce false;
  modules.apps.enable = lib.mkForce false;
  programs.vscode.enable = lib.mkForce false;

  # You still open its shell from Ghostty over SSH. Without Ghostty's terminfo,
  # vim, htop, less and tmux fail there with "unknown terminal type".
  modules.terminal.terminfo = true;
}
