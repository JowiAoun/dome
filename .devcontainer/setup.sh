#!/bin/bash

set -e

echo "🏠 Setting up dotfiles with Nix and Home Manager..."

# Check if Nix is already installed
if ! command -v nix &> /dev/null; then
    echo "📦 Installing Nix..."
    sh <(curl -L https://nixos.org/nix/install) --daemon --yes
    
    # Source nix for current session
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
else
    echo "✅ Nix is already installed"
fi

# Enable flakes
echo "🚀 Enabling Nix flakes..."
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

# Apply Home Manager configuration
echo "🔧 Applying Home Manager configuration..."
nix run home-manager/master -- switch --flake .#default

echo "✨ Dotfiles installation complete!"
echo "💡 Restart your shell or run 'exec \$SHELL' to apply all changes."