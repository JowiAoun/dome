# Dotfiles

Here's my simple development environment that works in WSL, GitHub Codespaces, and local environment.

> **ZenDuo project:** this repo also provisions a full Ubuntu 24.04 dual-boot on the
> ASUS Zenbook Duo (2024) UX8406MA. Start at **[docs/PLAN.md](docs/PLAN.md)** — the
> exhaustive, phase-gated master plan (research archive in
> [docs/research/](docs/research/)). The moving parts:
>
> - `system/` — idempotent root-layer scripts (`sudo make system HOST=zenbook-duo`,
>   add `DRY_RUN=1` as a make argument to preview)
> - `duo/` — **zenduo** hardware tooling; `duo doctor` is the read-only probe used as
>   the live-USB install gate
> - `hosts/` + `flake.nix` — per-machine home-manager profiles
>   (`home-manager switch --flake path:.#generic` or `path:.#zenbook-duo`)
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
`sudo bash system/run.sh --host <profile> --dry-run` (or
`sudo make system DRY_RUN=1`, once `build-essential` is installed). Use the flag
rather than `DRY_RUN=1 sudo …`: sudo's default `env_reset` drops the variable
before the script sees it, so that form would really apply the changes.
Non-Ubuntu distros: only
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

#### Desktop Apps (`modules.apps = true`)
GUI software **plus the desktop wiring that makes it usable** — desktop entries,
the default browser, and the GNOME dash:

- **Brave** — pinned to the dash (in Firefox's old slot) and set as the default
  browser for `http`/`https`/`text/html`; the Firefox pin is removed (the snap
  itself is left installed)
- **Discord** — pinned to the dash
- **Joplin** — pinned to the dash
- **draw.io**, **LocalSend**, **Bruno**, **OBS Studio** — installed, not pinned

Budget roughly **5 GiB** of disk for the set. To hold one back without
removing it from the module, name it in `appsSkip` — that is the same switch
the already-installed detection uses, so it also skips the pin and the desktop
entry:

```nix
appsSkip = [ "bruno" "obs-studio" "joplin" ];   # install later, keep the config
```

Add anything else from nixpkgs by name, no module edits needed:

```nix
# hosts/<name>/default.nix
modules.apps.extras = [ "obsidian" "vlc" "dbeaver-bin" ];
```

Worth knowing: on Ubuntu the GNOME session does **not** have the Nix profile on
`XDG_DATA_DIRS` or `PATH`, so a plain `home.packages` GUI app is invisible to the
dash and app grid. The module works around this by copying each app's
`.desktop` entry into `~/.local/share/applications` with `Exec=` and `Icon=`
rewritten to absolute `/nix/store` paths — which is why the apps show up
immediately, with icons, and with no re-login. `extras` are installed as plain
packages and skip that rewrite.

**GPU:** Nix packages look for DRI drivers under `/run/opengl-driver`, which
Ubuntu does not have, so out of the box a Nix GUI app gets no GL driver at all —
Flutter apps (LocalSend) refuse to start with *"No GL Implementation
Available"*, and Electron apps fall back to software rendering.
`system/80-nix-gpu.sh` fixes it by installing home-manager's `non-nixos-gpu`
systemd unit, which points `/run/opengl-driver` at a Mesa build matching the Nix
closure on every boot (`/run` is a tmpfs, so a plain symlink would not survive).
It runs as part of `sudo make system` and at the end of `./install.sh`. Re-run
it after `make update`: the bundle's store path changes, and home-manager will
say *"GPU drivers require an update"* on the next switch.

**VS Code gets the same treatment**, even though `programs.vscode` (not this
module) installs it — it has the same bare `Exec=code` and themed `Icon=vscode`,
so before this it was installed but absent from the app grid entirely. Its
entries are written whenever `programs.vscode.enable` is on, apps module or not.

The pins and default browser are **merged, not overwritten** (anything you
pinned yourself survives), by `~/.local/bin/apps-setup`. It runs during
`make home`; re-run it by hand if you activate from a TTY or over SSH, where
there is no D-Bus session to write to.

**Already have one of these from apt, snap or flatpak?** It is left completely
alone — no second copy, no pin, no change to its defaults:

```bash
./setup.sh --audit-apps       # full report: what is installed where, and what collides
./setup.sh --detect-apps      # just the names of apps already installed elsewhere
./setup.sh --sync-apps-skip   # record them in user-config.nix (install.sh does this too)
```

That writes `appsSkip = [ "brave" ];`, which drops the app from the module
entirely — no package, no desktop entry, no pin, never the default browser.
`vscode` is skippable the same way, and turns `programs.vscode` off with it.
Names you add by hand are kept. Detection only looks at system locations
(`/usr/share/applications`, snap and flatpak exports, `/usr/bin`, `/snap/bin`)
— deliberately never at the Nix profile, or the module would detect its own
installs and remove them on the next run.

`--audit-apps` also sweeps generically for the underlying failure mode: the
same `.desktop` id existing in two places, which is what puts two icons of one
app in the app grid. It reports what `gnome-shell` can actually see, so it can
tell a real duplicate from a harmless one.

Not enabled for the `generic` host profile — it also covers WSL and headless
machines.

### Docker

`docker` is **not** a Nix package here: the client is useless without a
root-owned daemon, and nixpkgs cannot give you a systemd unit, a socket, or the
`docker` group. So Docker Engine comes from the system layer instead —
`system/60-docker.sh` adds Docker's official apt repository and installs
`docker-ce`, `docker-ce-cli`, `containerd.io` and the buildx/compose plugins,
enables `docker.service`, and adds you to the `docker` group (root-equivalent,
by design — log out and back in for it to apply):

```bash
sudo make system            # includes Docker Engine when dockerEngine = true
docker run --rm hello-world # after a re-login
```

The user layer keeps `docker-compose` (a standalone binary, works against any
reachable daemon) and adds `lazydocker` as a TUI.

**Docker Desktop** is off by default — it is a ~450 MB download that runs its
own KVM virtual machine under a separate `docker context` (`desktop-linux`),
alongside rather than instead of the native engine. Turn it on with
`dockerDesktop = true;` in `user-config.nix`, or for one run:

```bash
sudo bash system/run.sh --docker-desktop
```

Both switches live outside `modules` in `user-config.nix`, because the root
layer reads them with `sed` rather than through Nix:

```nix
dockerEngine = true;    # Docker Engine (CE)
dockerDesktop = false;  # Docker Desktop GUI
```

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