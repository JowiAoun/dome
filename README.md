# Dotfiles

Here's my simple development environment that works in WSL, GitHub Codespaces, and local environment.

> **ZenDuo project:** this repo also provisions a full Ubuntu 24.04 dual-boot on the
> ASUS Zenbook Duo (2024) UX8406MA. Start at **[docs/PLAN.md](docs/PLAN.md)** — the
> exhaustive, phase-gated master plan (research archive in
> [docs/research/](docs/research/)). The moving parts:
>
> - `system/` — idempotent root-layer scripts (`sudo make system HOST=zenbook-duo`,
>   `DRY_RUN=1` to preview)
> - `duo/` — **zenduo** hardware tooling; `duo doctor` is the read-only probe used as
>   the live-USB install gate
> - `hosts/` + `flake.nix` — per-machine home-manager profiles
>   (`home-manager switch --flake .#generic` or `.#zenbook-duo`)
> - `install.sh` — one-command setup on a fresh Ubuntu machine

## Quick Start — pick your machine's path

| Machine | Path |
|---------|------|
| GitHub Codespaces | Enable dotfiles (below) — `bootstrap.sh` runs automatically |
| WSL / existing Linux that already has (or wants only) Nix | `./bootstrap.sh` (interactive) |
| **Fresh Ubuntu 24.04 machine — any hardware** | `./install.sh --host generic` |
| ASUS Zenbook Duo (2024) UX8406MA | Follow [docs/PLAN.md](docs/PLAN.md) + [docs/CHECKLIST.md](docs/CHECKLIST.md), then `./install.sh --host zenbook-duo` |

### GitHub Codespaces
1. Go to [GitHub Settings → Codespaces](https://github.com/settings/codespaces)
2. Enable "Automatically install dotfiles" 
3. Set repository to your fork or clone of this repo
4. Create a new Codespace - setup runs automatically!

### Fresh Ubuntu machine (any hardware)
```bash
sudo apt install -y git   # the only manual prerequisite (dome's base layer also installs it)
git clone https://github.com/JowiAoun/dome.git ~/.dotfiles
cd ~/.dotfiles
./setup.sh                # guided TUI: detects the machine, picks the host
                          # profile, toggles modules, writes user-config.nix,
                          # and offers to run the full install
```
`setup.sh` detects distro/hardware/WSL/Codespaces, suggests the right
`hosts/<name>` profile (e.g. the Zenbook Duo is auto-recognized by DMI model),
seeds the module checklist from that host's committed defaults
(`hosts/<name>/setup-defaults.env` — the Duo ships with `cloud` off), and
preserves your saved choices on re-runs.

Headless/scripted alternative (same result, no prompts):
```bash
./setup.sh --defaults zenbook-duo         # write user-config.nix from host seeds
./install.sh --host zenbook-duo           # flags: --enable/--disable python,node,java,ai,cloud
```
The install runs, in order: **user-config.nix** environment re-detection, the
**system layer** (apt basics, HWE+GA kernels, GRUB os-prober — duo-only steps
are skipped on generic hosts), the official **Nix** installer, and
**home-manager** for the chosen host. Re-run any time; every step is
idempotent. Preview root-level changes with
`DRY_RUN=1 sudo bash system/run.sh --host <profile>` (the `make system` alias
works too, once `build-essential` is installed). Non-Ubuntu distros: only
`bootstrap.sh` applies (the system layer refuses to run without `FORCE=1`).

### WSL / existing Linux
```bash
# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Clone and setup
git clone https://github.com/JowiAoun/dome.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

### Adding a new machine profile
1. `cp -r hosts/generic hosts/<name>` and edit it (import machine modules, set options)
2. Add `homeConfigurations.<name> = mkHome "<name>";` in `flake.nix`
3. `./install.sh --host <name>`

Machine-specific code lives in `modules/<name>/` and is imported **only** by
that host's profile — every other machine never evaluates it (that's how the
Zenbook Duo tooling stays out of generic setups).

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
- Node.js v22 LTS (global) with npm and pnpm
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
home-manager switch --flake path:.#generic -b backup   # or your host profile

# Update packages
nix flake update
```

Note the `path:.` — a plain `.` flake ref copies only git-*tracked* files, which
would silently skip your git-ignored `user-config.nix`.

## Updating & recovering

`make update` bumps the pinned inputs in `flake.lock` — nixpkgs, home-manager,
and therefore every `pkgs.*` package. The repo tracks `nixos-unstable`, which is
newest but occasionally ships a **mid-transition snapshot** (e.g. a glibc
mass-rebuild in progress) where core tools like `git` or `vscode` fail at runtime
with `GLIBC_ABI_* not found` errors.

If an update misbehaves, undo it with one command:

```bash
make rollback   # restore flake.lock to the committed pin and re-activate
```

`make rollback` reverts the lockfile and rebuilds via `nix run
home-manager/master`, which works **even when the bad update left the profile's
`git`/`home-manager` broken** (nix's own fetcher doesn't depend on those). It's
just `git restore flake.lock` + a re-activation — safe to run any time.

**Prefer stability over newest?** Point the flake at a stable release instead of
unstable. Claude (official installer) and Gemini (npm) stay on the latest either
way, so the only cost is slightly older system packages — no more mid-rebuild
breakage:

```nix
# flake.nix — use the current stable release (25.05 as of mid-2026)
nixpkgs.url      = "github:NixOS/nixpkgs/nixos-25.05";
home-manager.url = "github:nix-community/home-manager/release-25.05";
```

Then `nix flake update && make home` to re-lock onto the stable channel.

## Why This Setup?

- **Declarative**: Everything defined in code
- **Reproducible**: Same setup, everywhere
- **Modular**: Only install what you need
- **Cross-platform**: Works on any Linux/macOS
- **Version Control**: Your entire dev environment in git

## Structure

```
dome/
├── install.sh             # Full-machine setup (system layer + Nix + home-manager)
├── bootstrap.sh           # User-layer-only setup (Codespaces/WSL)
├── Makefile               # make system / home / doctor / update
├── user-config.nix        # Your settings (git-ignored, never committed)
├── user-config.template.nix # Template for user-config.nix
├── flake.nix              # Nix flake definition (host-profile outputs)
├── home.nix               # Main home-manager configuration
├── hosts/                 # Per-machine profiles (generic, zenbook-duo, ...)
├── modules/               # Development environments + machine modules
│   ├── python.nix         # Python + pyenv
│   ├── node.nix           # Node.js + nodenv
│   ├── java.nix           # Java development
│   ├── ai.nix             # AI tools
│   ├── cloud.nix          # Terraform/Pulumi/cloud CLIs/k8s
│   └── zenbook-duo/       # Duo-only home-manager wiring
├── system/                # Idempotent root-layer scripts (Ubuntu)
├── duo/                   # zenduo hardware tooling (self-contained, MIT)
└── docs/                  # PLAN.md, CHECKLIST.md, research archive
```

## Secrets policy

This is a public repository — treat it accordingly:

- `user-config.nix` (name, email, host, module choices) is **git-ignored**;
  only the neutral template is tracked, and CI fails if the real file ever
  becomes tracked.
- No keys, tokens, or passphrases belong anywhere in the tree. CI runs a
  gitleaks scan on every push/PR as a backstop.
- Future encrypted secrets (API tokens etc.) are planned via `sops-nix`
  (age-encrypted, safe to commit — see docs/PLAN.md G6). Until then, keep
  secrets out entirely.

## Troubleshooting

**Nix not found after install:**
```bash
source ~/.nix-profile/etc/profile.d/nix.sh
```

**File conflicts during setup:**
```bash
home-manager switch --flake path:.#generic -b backup   # or your host profile
```

---

**License**: MIT - Feel free to clone, fork, make it your own. I tried to make it easy to setup with just 1 script.