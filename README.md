# 🏠 Dotfiles Configuration

A modern, cross-platform dotfiles setup using **Nix** and **Home Manager** with automatic installation in **GitHub Codespaces**.

## 🚀 Quick Start

### For GitHub Codespaces (Recommended)

1. **Enable automatic dotfiles installation:**
   - Go to [GitHub Settings → Codespaces](https://github.com/settings/codespaces)
   - Check "Automatically install dotfiles"
   - Set repository to `your-username/dome`

2. **Create a new Codespace** - Your dotfiles will be automatically installed!

### For Local/Other Environments

1. **Install Nix:**
   ```bash
   sh <(curl -L https://nixos.org/nix/install) --daemon
   ```

2. **Enable flakes:**
   ```bash
   mkdir -p ~/.config/nix
   echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf
   ```

3. **Clone and apply:**
   ```bash
   git clone https://github.com/your-username/dome.git ~/.dotfiles
   cd ~/.dotfiles
   nix run home-manager/master -- switch --flake .#default
   ```

## 📁 Repository Structure

```
dome/
├── README.md              # This file
├── bootstrap.sh           # GitHub Codespaces installation script (collects user info)
├── user-config.nix        # Centralized user configuration
├── flake.nix             # Nix flake definition
├── home.nix              # Main Home Manager configuration (local)
├── home-codespaces.nix   # Codespaces-optimized configuration
└── modules/              # Modular development environments
    ├── default.nix       # Module system setup
    ├── python.nix        # Python development tools
    ├── node.nix          # Node.js development tools
    ├── java.nix          # Java development tools
    └── ai.nix            # AI development tools (Claude Code)
```

## ⚙️ Configurations

### Two Configuration Profiles

1. **`home.nix`** - Full configuration for local environments
   - Includes all development modules
   - Full system integration

2. **`home-codespaces.nix`** - Streamlined for GitHub Codespaces
   - Avoids package conflicts with pre-installed tools
   - Optimized for container environments

### Available Configurations

- **`default`** - Uses Codespaces config (auto-detects environment)
- **`codespaces`** - Explicitly uses Codespaces config
- **`vscode`** - Uses full local config

## 🛠️ What Gets Installed

### Core Tools (Always Installed)
- **Shell**: Zsh with completions, syntax highlighting, and vi-mode
- **Editor**: Vim with sensible defaults
- **Git**: Configured with aliases and settings
- **GitHub**: CLI tool (`gh`) with Copilot extensions
- **Terminal**: Tmux with custom keybindings
- **Utils**: fzf, ripgrep, fd, bat, htop, tree, lazygit

### Development Modules (Configurable)

#### Python Module (`modules.python.enable = true`)
- Python 3 with pip and virtualenv
- Shell aliases: `py`, `pip`, `venv`, `jupyter-lab`
- Pycodestyle configuration

#### Node.js Module (`modules.node.enable = true`)
- Node.js 20 with npm, pnpm, TypeScript
- Shell aliases: `pi`, `ps`, `pt`, `pb`, `pd`, `px`
- Global npm configuration

#### Java Module (`modules.java.enable = false`)
- JDK 21, Maven, Gradle, Spring Boot CLI
- Maven settings configuration
- Shell aliases for common Maven/Gradle commands

#### AI Tools Module (`modules.ai.enable = true`)
- **Claude Code**: Anthropic's official CLI for AI development assistance
- **Setup script**: `~/.local/bin/ai-setup` for quick environment setup
- **Tips & docs**: `~/.local/share/ai-tips.md` with usage examples
- **GitHub Copilot**: Available via `gh copilot` (pre-installed with GitHub CLI)

## 🎨 Shell Features

### Zsh Configuration
- **Theme**: Clean adam1 prompt
- **Vi Mode**: Enabled with proper keybindings
- **History**: 10k entries with smart search
- **Completions**: Auto-suggestions and syntax highlighting

### Bash Aliases (Available in both Bash and Zsh)
```bash
ll        # ls -l
la        # ls -la
..        # cd ..
l         # lazygit
lg        # lazygit (alternative)
```

### Tmux Setup
- **Prefix**: `Ctrl-a` (instead of default `Ctrl-b`)
- **Splits**: `prefix + v` (vertical), `prefix + s` (horizontal)
- **Navigation**: `prefix + h/j/k/l` (vim-like pane switching)
- **Features**: Mouse support, 50k history, base index 1

### AI Tools Usage
```bash
# Start AI environment
ai-setup                         # Quick setup script

# Claude Code (Interactive AI assistant)
claude                          # Start Claude Code interactive session

# GitHub Copilot CLI (requires auth)
gh auth login                   # Authenticate for Copilot features
gh copilot explain "git rebase" # Explain commands
gh copilot suggest "compress"   # Get suggestions
gh copilot suggest -t shell     # Shell command suggestions
```

## 👤 Personalization

### User Configuration

All personal information (name, email, preferences) is centralized in `user-config.nix`. The bootstrap script will automatically prompt for this information on first run:

```bash
# When you run bootstrap.sh, you'll be prompted:
Enter your full name [John Doe]: Your Actual Name
Enter your email [john.doe@example.com]: your.actual@email.com
```

You can also manually edit `user-config.nix`:

```nix
{
  name = "Your Actual Name";
  email = "your.actual@email.com";
  
  # Additional preferences
  gitDefaultBranch = "main";
  gitEditor = "vim";
  preferredShell = "zsh";
  preferredEditor = "vim";
}
```

### Enabling/Disabling Development Modules

Edit the configuration files:

**For local environments** (`home.nix`):
```nix
modules = {
  python.enable = true;   # Python tools
  node.enable = true;     # Node.js tools  
  java.enable = false;    # Java tools (disabled)
  ai.enable = true;       # AI development tools
};
```

**For Codespaces**: Development tools are minimal to avoid conflicts, but AI tools are enabled:
```nix
modules = {
  python.enable = false;  # Pre-installed in Codespaces
  node.enable = false;    # Pre-installed in Codespaces  
  java.enable = false;    # Not needed by default
  ai.enable = true;       # AI tools are useful everywhere!
};
```

### Adding Custom Packages

Add packages to the `home.packages` list:

```nix
home.packages = with pkgs; [
  # Existing packages...
  docker
  kubectl
  terraform
];
```

### Custom Shell Aliases

Add to the `shellAliases` sections in the configuration:

```nix
programs.bash.shellAliases = {
  # Existing aliases...
  dc = "docker-compose";
  k = "kubectl";
};
```

### Git Configuration

Git configuration is automatically populated from `user-config.nix`. All files reference the centralized configuration:

```nix
# This is automatically configured from user-config.nix
programs.git = {
  enable = true;
  userName = userConfig.name;     # From user-config.nix
  userEmail = userConfig.email;   # From user-config.nix
  extraConfig = {
    init.defaultBranch = userConfig.gitDefaultBranch;
    core.editor = userConfig.gitEditor;
  };
};
```

## 🔧 Updating

### Update Dotfiles
```bash
cd ~/.dotfiles  # or your dotfiles directory
git pull
home-manager switch --flake .#default
```

### Update Nix Packages
```bash
cd ~/.dotfiles
nix flake update
home-manager switch --flake .#default
```

## 🐛 Troubleshooting

### Codespaces Installation Failed

1. **Check the creation logs** in the Codespaces interface
2. **Common issues:**
   - Package conflicts → Use Codespaces config (`home-codespaces.nix`)
   - File conflicts → Bootstrap script uses `-b backup` to handle this
   - Permission issues → Single-user Nix install is used automatically

### Local Installation Issues

1. **Nix not in PATH:**
   ```bash
   . ~/.nix-profile/etc/profile.d/nix.sh
   ```

2. **Home Manager not found:**
   ```bash
   nix run home-manager/master -- --help
   ```

3. **Configuration conflicts:**
   ```bash
   home-manager switch --flake .#default -b backup
   ```

### Switching Between Configurations

```bash
# Use Codespaces config
home-manager switch --flake .#codespaces

# Use local config  
home-manager switch --flake .#vscode

# Use default (auto-detects environment)
home-manager switch --flake .#default
```

## 📚 Learn More

- [Nix Package Manager](https://nixos.org/)
- [Home Manager](https://github.com/nix-community/home-manager)
- [GitHub Codespaces Dotfiles](https://docs.github.com/en/codespaces/customizing-your-codespace/personalizing-github-codespaces-for-your-account#dotfiles)

## 📄 License

This configuration is free under the MIT license to use and modify for personal use.

---

**Note**: The bootstrap script will automatically collect your personal information on first run. No manual editing of multiple files is required!