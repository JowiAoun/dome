#!/bin/bash

set -e

# Function to retry commands
retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔄 Attempt $attempt/$max_attempts: $*"
        if "$@"; then
            return 0
        else
            echo "⚠️  Command failed (attempt $attempt/$max_attempts)"
            if [ $attempt -lt $max_attempts ]; then
                echo "😴 Waiting $delay seconds before retry..."
                sleep $delay
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    echo "❌ Command failed after $max_attempts attempts: $*"
    return 1
}

# Function to wait for system to be ready
wait_for_system() {
    echo "⏳ Waiting for Codespaces environment to be ready..."
    
    # Wait for basic commands to be available
    local max_wait=30
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
            echo "✅ System is ready"
            return 0
        fi
        echo "⏳ System not ready yet, waiting... ($waited/$max_wait)"
        sleep 2
        waited=$((waited + 2))
    done
    
    echo "⚠️  System readiness check timed out, proceeding anyway..."
}

echo "🏠 Setting up dotfiles in GitHub Codespaces..."
echo "📊 Environment info: USER=$USER, HOME=$HOME"

# Wait for Codespaces to be fully ready
if [ "$USER" = "codespace" ] || [ ! -z "$CODESPACES" ] || [ ! -z "$CODESPACE_NAME" ]; then
    wait_for_system
fi

# Check if Nix is already installed
if command -v nix &> /dev/null; then
    echo "✅ Nix is already installed"
    # Source nix for current session
    if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    elif [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
else
    # For Codespaces, use the single-user Nix installation to avoid permission issues
    if [ "$USER" = "codespace" ] || [ ! -z "$CODESPACES" ] || [ ! -z "$CODESPACE_NAME" ]; then
        echo "📦 Installing Nix for Codespaces (single-user mode)..."
        
        # Single-user installation for Codespaces with retry
        retry sh -c 'curl -L https://nixos.org/nix/install | sh -s -- --no-daemon'
        
        # Source nix for current session
        if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
            . "$HOME/.nix-profile/etc/profile.d/nix.sh"
        fi
        
        # Add to shell profiles (only if not already there)
        if ! grep -q "nix-profile.*nix.sh" ~/.bashrc 2>/dev/null; then
            echo ". $HOME/.nix-profile/etc/profile.d/nix.sh" >> ~/.bashrc
        fi
        if ! grep -q "nix-profile.*nix.sh" ~/.profile 2>/dev/null; then
            echo ". $HOME/.nix-profile/etc/profile.d/nix.sh" >> ~/.profile
        fi
        
    else
        echo "📦 Installing Nix (daemon mode)..."
        # Standard multi-user installation for other environments
        retry sh -c 'curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes'
        
        # Source nix for current session
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        fi
    fi
fi

# Ensure PATH includes nix
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# Verify nix is available with retry
echo "🔍 Verifying Nix installation..."
if ! retry command -v nix; then
    echo "❌ Nix installation failed or not in PATH"
    echo "📋 PATH: $PATH"
    echo "📁 Home directory contents:"
    ls -la "$HOME"
    exit 1
fi

echo "✅ Nix installed successfully at: $(command -v nix)"
echo "📋 Nix version: $(nix --version)"

# Enable flakes
echo "🚀 Enabling Nix flakes..."
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

# Apply Home Manager configuration with retry
echo "🔧 Applying Home Manager configuration..."
echo "📁 Backing up existing dotfiles..."

# Retry the home-manager installation
if retry nix run home-manager/master -- switch --flake .#default -b backup; then
    echo "✅ Home Manager configuration applied successfully!"
else
    echo "❌ Home Manager configuration failed"
    echo "🔍 Debugging info:"
    echo "Current directory: $(pwd)"
    echo "Directory contents:"
    ls -la
    echo "Nix info:"
    nix --version || echo "Nix version failed"
    echo "Home Manager test:"
    nix run home-manager/master -- --help || echo "Home Manager test failed"
    exit 1
fi

echo "✨ Dotfiles installation complete!"
echo "💡 Restart your shell or run 'source ~/.bashrc' to apply all changes."
echo "🎉 You can also run 'exec \$SHELL' to reload your shell immediately."