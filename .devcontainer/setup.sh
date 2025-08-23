#!/bin/bash

echo "Starting dotfiles setup..."

# Check if running as vscode user
if [ "$(whoami)" != "vscode" ]; then
    echo "Warning: Not running as vscode user, current user: $(whoami)"
fi

# Install Nix (single-user mode for codespaces)
echo "Installing Nix..."
curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon

# Check if Nix installation succeeded
if [ ! -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    echo "Nix installation failed - profile script not found"
    exit 1
fi

# Source Nix environment
echo "Setting up Nix environment..."
source "$HOME/.nix-profile/etc/profile.d/nix.sh"

# Verify Nix installation
if ! command -v nix >/dev/null 2>&1; then
    echo "Nix command not available after installation"
    exit 1
fi

echo "Nix version: $(nix --version)"

# Enable flakes
echo "Enabling flakes..."
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

# Update home.nix username to match codespace user
echo "Configuring for vscode user..."
if [ -f "home.nix" ]; then
    sed -i 's/home.username = "user";/home.username = "vscode";/' home.nix
    sed -i 's|home.homeDirectory = "/home/user";|home.homeDirectory = "/home/vscode";|' home.nix
else
    echo "Warning: home.nix not found in current directory"
    ls -la
fi

# Install and apply home-manager
echo "Setting up Home Manager..."
if ! nix run home-manager/master -- switch --flake .#default -b backup; then
    echo "Home Manager setup failed"
    exit 1
fi

# Add Nix to shell profile permanently
echo "Adding Nix to shell profiles..."
echo 'if [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then . ~/.nix-profile/etc/profile.d/nix.sh; fi' >> ~/.bashrc
echo 'if [ -f ~/.nix-profile/etc/profile.d/nix.sh ]; then . ~/.nix-profile/etc/profile.d/nix.sh; fi' >> ~/.zshrc

# Change default shell to zsh if it was installed
if command -v zsh >/dev/null 2>&1; then
    echo "Changing default shell to zsh..."
    sudo chsh -s $(which zsh) vscode || echo "Failed to change shell, continuing..."
fi

echo "Dotfiles setup complete!"
echo "Please restart your terminal or run: source ~/.bashrc"