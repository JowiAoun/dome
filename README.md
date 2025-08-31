# Dotfiles

Here's my simple development environment that works in WSL, GitHub Codespaces, and local environment.

## Quick Start

### GitHub Codespaces
1. Go to [GitHub Settings → Codespaces](https://github.com/settings/codespaces)
2. Enable "Automatically install dotfiles" 
3. Set repository to your fork or clone of this repo
4. Create a new Codespace - setup runs automatically!

### Local Setup
```bash
# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Clone and setup
git clone https://github.com/your-username/dome.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

## What You Get

### Core Tools
- **Shell**: Zsh with oh-my-zsh and sensible defaults, and a nice theme using [starship](https://github.com/starship/starship)
- **Editor**: VSCode suggested extensions for each module chosen
- **Git**: Pre-configured with your details
- **Utils**: fzf, ripgrep, bat, tree, lazygit

### Development Modules (Choose During Setup)

#### Python (`modules.python = true`)
- Python 3.13 with pip
- **pyenv** for version management
- VS Code extensions: Python, Pylance, Black, Flake8

#### Node.js (`modules.node = true`) 
- Node.js v24 LTS (global) with npm and pnpm
- **nodenv** for version management
- VS Code extensions: ESLint, Prettier, TailwindCSS

#### Java (`modules.java = true`)
- JDK 21, Maven, Gradle
- VS Code Java extensions

#### AI Tools (`modules.ai = true`)
- **Claude Code**: AI coding assistant

## Configuration

Your personal settings are stored in `user-config.nix` (git-ignored):

```nix
{
  name = "Your Name";
  email = "your@email.com";
  
  modules = {
    python = true;   # Enable Python tools
    node = true;     # Enable Node.js tools  
    java = false;    # Disable Java tools
    ai = true;       # Enable AI tools
  };
}
```

## Common Commands

```bash
# Version management
pyenv install 3.12.0    # Install Python version
pyenv global 3.12.0     # Set global Python
nodenv install 20.0.0   # Install Node version  
nodenv global 20.0.0    # Set global Node

# Update dotfiles
cd ~/.dotfiles && git pull
home-manager switch --flake .#$USER

# Update packages
nix flake update
```

## Why This Setup?

- **Declarative**: Everything defined in code
- **Reproducible**: Same setup, everywhere
- **Modular**: Only install what you need
- **Cross-platform**: Works on any Linux/macOS
- **Version Control**: Your entire dev environment in git

## Structure

```
dome/
├── bootstrap.sh           # Setup script
├── user-config.nix        # Your settings (git-ignored)
├── user-config.template.nix # Template for user-config.nix
├── flake.nix              # Nix flake definition
├── home.nix               # Main configuration
└── modules/               # Development environments
    ├── python.nix         # Python + pyenv
    ├── node.nix           # Node.js + nodenv  
    ├── java.nix           # Java development
    └── ai.nix             # AI tools
```

## Troubleshooting

**Nix not found after install:**
```bash
source ~/.nix-profile/etc/profile.d/nix.sh
```

**File conflicts during setup:**
```bash
home-manager switch --flake .#$USER -b backup
```

---

**License**: MIT - Feel free to clone, fork, make it your own. I tried to make it easy to setup with just 1 script.