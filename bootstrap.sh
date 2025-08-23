#!/bin/bash

set -e

echo "🏠 Setting up dotfiles in GitHub Codespaces..."

# Check if we're in Codespaces
if [ -z "$CODESPACES" ] && [ -z "$CODESPACE_NAME" ]; then
    echo "⚠️  Not running in GitHub Codespaces, using standard Nix installation"
fi

# For Codespaces, use the single-user Nix installation to avoid permission issues
if [ ! -z "$CODESPACES" ] || [ ! -z "$CODESPACE_NAME" ] || [ "$USER" = "codespace" ]; then
    echo "📦 Installing Nix for Codespaces (single-user mode)..."
    
    # Single-user installation for Codespaces
    sh <(curl -L https://nixos.org/nix/install) --no-daemon
    
    # Source nix for current session
    if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
    
    # Add to shell profiles
    echo ". $HOME/.nix-profile/etc/profile.d/nix.sh" >> ~/.bashrc
    echo ". $HOME/.nix-profile/etc/profile.d/nix.sh" >> ~/.profile
    
else
    echo "📦 Installing Nix (daemon mode)..."
    # Standard multi-user installation for other environments
    sh <(curl -L https://nixos.org/nix/install) --daemon --yes
    
    # Source nix for current session
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
fi

# Ensure PATH includes nix
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# Verify nix is available
if ! command -v nix &> /dev/null; then
    echo "❌ Nix installation failed or not in PATH"
    exit 1
fi

echo "✅ Nix installed successfully"

# Enable flakes
echo "🚀 Enabling Nix flakes..."
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

# Apply Home Manager configuration
echo "🔧 Applying Home Manager configuration..."
echo "📁 Backing up existing dotfiles..."
nix run home-manager/master -- switch --flake .#default -b backup

echo "✨ Dotfiles installation complete!"
echo "💡 Restart your shell or run 'source ~/.bashrc' to apply all changes."