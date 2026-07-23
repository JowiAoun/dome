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

# Escape a string for safe use as a sed s|...|REPLACEMENT| replacement:
# `&` expands to the whole match and `|` ends the expression, so an unescaped
# name like "AT&T Admin" would corrupt user-config.nix into invalid Nix.
sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

# Function to detect environment
detect_environment() {
    local is_codespaces=false
    local is_wsl=false
    local username="$USER"
    local home_dir="$HOME"
    
    # Detect Codespaces
    if [ "$USER" = "codespace" ] || [ -n "$CODESPACES" ] || [ -n "$CODESPACE_NAME" ]; then
        is_codespaces=true
        username="codespace"
        home_dir="/home/codespace"
    fi
    
    # Detect WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        is_wsl=true
    fi
    
    echo "🔍 Environment detected:"
    echo "   Codespaces: $is_codespaces"
    echo "   WSL: $is_wsl" 
    echo "   User: $username"
    
    # Update environment in user-config.nix
    sed -i "s|isCodespaces = .*;|isCodespaces = $is_codespaces;|" user-config.nix
    sed -i "s|isWSL = .*;|isWSL = $is_wsl;|" user-config.nix
    sed -i "s|username = \".*\";|username = \"$username\";|" user-config.nix
    sed -i "s|homeDirectory = \".*\";|homeDirectory = \"$home_dir\";|" user-config.nix
}

# Function to collect module preferences
collect_module_preferences() {
    echo ""
    echo "📦 Choose development modules to install:"
    echo "   (This determines which tools and VS Code extensions are installed)"
    echo ""
    
    # Python module
    read -rp "Install Python development tools? (y/N): " python_choice
    python_enabled=$([ "$python_choice" = "y" ] || [ "$python_choice" = "Y" ] && echo "true" || echo "false")
    
    # Node.js module
    read -rp "Install Node.js development tools? (y/N): " node_choice
    node_enabled=$([ "$node_choice" = "y" ] || [ "$node_choice" = "Y" ] && echo "true" || echo "false")
    
    # Java module
    read -rp "Install Java development tools? (y/N): " java_choice
    java_enabled=$([ "$java_choice" = "y" ] || [ "$java_choice" = "Y" ] && echo "true" || echo "false")
    
    # AI module (default yes)
    read -rp "Install AI tools (Claude Code)? (Y/n): " ai_choice
    ai_enabled=$([ "$ai_choice" = "n" ] || [ "$ai_choice" = "N" ] && echo "false" || echo "true")
    
    # Update module selections in user-config.nix
    sed -i "s|python = .*;|python = $python_enabled;|" user-config.nix
    sed -i "s|node = .*;|node = $node_enabled;|" user-config.nix
    sed -i "s|java = .*;|java = $java_enabled;|" user-config.nix
    sed -i "s|ai = .*;|ai = $ai_enabled;|" user-config.nix
    
    echo ""
    echo "✅ Module preferences saved:"
    echo "   Python: $python_enabled"
    echo "   Node.js: $node_enabled"  
    echo "   Java: $java_enabled"
    echo "   AI Tools: $ai_enabled"
}

# Function to collect user information
collect_user_info() {
    echo "👤 Setting up user configuration..."
    
    # Create user-config.nix from template if it doesn't exist
    if [ ! -f user-config.nix ]; then
        echo "📋 Creating personal configuration from template..."
        cp user-config.template.nix user-config.nix
    fi
    
    # Check if user-config.nix has placeholder values
    if grep -q "Your Full Name\|your.email@example.com" user-config.nix 2>/dev/null; then
        echo "🔧 Collecting user information for personalization..."
        
        # Get user's name with default
        read -rp "Enter your full name [Jowi Aoun]: " user_name
        user_name=${user_name:-"Jowi Aoun"}
        
        # Get user's email with default
        read -rp "Enter your email [83415433+JowiAoun@users.noreply.github.com]: " user_email
        user_email=${user_email:-"83415433+JowiAoun@users.noreply.github.com"}
        
        # Update user-config.nix with collected information
        sed -i "s|name = \".*\";|name = \"$(sed_escape "$user_name")\";|" user-config.nix
        sed -i "s|email = \".*\";|email = \"$(sed_escape "$user_email")\";|" user-config.nix
        
        echo "✅ User configuration updated with:"
        echo "   Name: $user_name"
        echo "   Email: $user_email"
        
        # Collect module preferences
        collect_module_preferences
        
        # Detect and update environment
        detect_environment
    else
        echo "✅ User configuration already personalized"
        # Always update environment detection even if config exists
        detect_environment
    fi
}

echo "🏠 Setting up dotfiles in GitHub Codespaces..."
echo "📊 Environment info: USER=$USER, HOME=$HOME"

# Collect user information for personalization
collect_user_info

# Wait for Codespaces to be fully ready
if [ "$USER" = "codespace" ] || [ -n "$CODESPACES" ] || [ -n "$CODESPACE_NAME" ]; then
    wait_for_system
fi

# Check if Nix is already installed
if [ -f "/nix/var/nix/profiles/default/bin/nix" ] || command -v nix &> /dev/null; then
    echo "✅ Nix is already installed"
    # Source nix for current session and add to PATH
    export PATH="/nix/var/nix/profiles/default/bin:$PATH"
    if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    elif [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    elif [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix.sh'
    fi
else
    # For Codespaces, use the single-user Nix installation to avoid permission issues
    if [ "$USER" = "codespace" ] || [ -n "$CODESPACES" ] || [ -n "$CODESPACE_NAME" ]; then
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
# Append, never overwrite: `>` would wipe any other user-level nix settings
# (substituters, access-tokens for private flakes, max-jobs). Same as install.sh.
if ! grep -qs 'experimental-features' ~/.config/nix/nix.conf; then
    echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
fi

# Apply Home Manager configuration with retry
echo "🔧 Applying Home Manager configuration..."
echo "📁 Backing up existing dotfiles..."

# Select the flake output by HOST PROFILE, not by $USER: the username-keyed
# outputs only exist for user/jaoun/codespace, so every other WSL account (the
# common case) failed with "does not provide attribute homeConfigurations.<name>".
# username/homeDirectory already reach the config through user-config.nix, which
# detect_environment just rewrote — so the host profile is all that's needed.
PROFILE="$(sed -nE 's/.*hostProfile *= *"([^"]+)".*/\1/p' user-config.nix 2>/dev/null | head -n1)"
PROFILE="${PROFILE:-generic}"
echo "🏷️  Host profile: $PROFILE"

# Retry the home-manager installation
# path:. (not plain .) so the gitignored user-config.nix is included in the
# flake source — a git+file flake copies tracked files only.
if retry nix --extra-experimental-features nix-command --extra-experimental-features flakes run home-manager/master -- switch --flake path:.#"$PROFILE" -b backup; then
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