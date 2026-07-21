# Plan: Making the `dome` repo reproducibly set up Ubuntu 24.04 LTS on the Zenbook Duo (with an optional, modular Duo profile)
 
## TL;DR
 
- **Keep Nix, but evolve it — don't throw it away.** Your `dome` repo is already a standalone **home-manager flake**, which in 2025–2026 is still state-of-the-art for declarative *user-layer* config. It is not "an old way of doing things," but the current version is a bit dated in mechanics (impure `builtins.getEnv "USER"`, `sed`-mutated `user-config.nix`, no `hosts/`, no editor/terminal dotfiles, no GUI/system layer). The best path is a **principled hybrid**: keep home-manager (flake-based) for the user layer, add a small **idempotent shell/`Makefile` "system layer"** for the things Nix cannot cleanly do on Ubuntu (HWE kernel, GRUB `i915.enable_psr=0`, apt/drivers, GDM/GNOME system settings), and make the **Zenbook Duo scripts an optional `hosts/zenbook-duo` profile** that is off by default.
- **Toggle machine-specific modules with an explicit `hosts/<hostname>` layout keyed on the real hostname** (a `homeConfigurations.<hostname>` output per machine), not with `$USER` string-matching. A generic (`hosts/generic`) profile sets up a new, non-Duo machine with zero Duo baggage; `hosts/zenbook-duo` adds the Duo module by importing one extra file.
- **Secrets stay out of the Nix store.** Use `sops-nix` (age-encrypted, committable) or the existing pattern of a git-ignored local file for SSH keys/tokens/git credentials; never put unencrypted secrets in flake files (they are world-readable in `/nix/store`).
---
 
## Key Findings
 
**1. Inventory of the current `dome` repo (read directly from GitHub).** The repo (`JowiAoun/dome`, description "My development environment," MIT, ~46 commits, 1 star, languages **Nix 78.5% / Shell 21.5%**) currently contains:
 
- `flake.nix` — a **standalone home-manager flake** with inputs `nixpkgs` (`github:NixOS/nixpkgs/nixos-unstable`) and `home-manager` (`github:nix-community/home-manager`, `inputs.nixpkgs.follows = "nixpkgs"`). It hardcodes `system = "x86_64-linux"`, reads the user impurely via `builtins.getEnv "USER"`, and exposes `homeConfigurations` keyed by *username* (`default`, `user`, `jaoun`, `codespace`, plus `vscode`/`codespaces` aliases). It passes `_module.args.userConfigPath = ./user-config.nix`.
- `home.nix` — the main home-manager config (the entrypoint that imports modules).
- `modules/` — per-**language** dev modules: `python.nix` (Python 3.13 + pyenv), `node.nix` (Node 24 LTS + nodenv + pnpm), `java.nix` (JDK 21, Maven, Gradle), `ai.nix` (Claude Code). These are toggled by booleans.
- `user-config.nix` (git-ignored) + `user-config.template.nix` — holds `name`, `email`, and a `modules = { python; node; java; ai; }` boolean set, plus environment flags `isCodespaces` / `isWSL` / `username` / `homeDirectory`.
- `bootstrap.sh` — an interactive installer that: detects environment (Codespaces via `$CODESPACES`/`$CODESPACE_NAME`, WSL via `grep -qi microsoft /proc/version`), copies the template to `user-config.nix`, **prompts** for name/email and module choices, **`sed`-mutates `user-config.nix`**, installs Nix (single-user for Codespaces, `--daemon` elsewhere) with a retry helper, enables flakes in `~/.config/nix/nix.conf`, then runs `nix run home-manager/master -- switch --flake .#$USER -b backup`.
- Tooling it manages today: **Zsh + oh-my-zsh + Starship prompt**, VS Code suggested extensions per module, **git** (name/email), and CLI utils **fzf, ripgrep, bat, tree, lazygit**. Platforms targeted: **WSL, GitHub Codespaces, local Linux/macOS**.
**What is NOT in the repo today** (gaps the Ubuntu plan must fill): no `hosts/`/per-machine profiles; no editor config beyond VS Code extension hints (no Neovim/tmux dotfiles); no terminal-emulator, font, or GNOME/desktop config; no system layer at all (no apt, kernel, GRUB, drivers, systemd system services); `x86_64-linux` hardcoded; impure username handling.
 
**2. Is Nix/home-manager "outdated"? No.** home-manager's README (nix-community) states standalone home-manager is the recommended and, for non-NixOS, *only* choice for managing your home independently of the system. For non-NixOS Linux it provides `targets.genericLinux.enable = true;` which sets `XDG_DATA_DIRS` (including `/usr/share/ubuntu`, `/var/lib/snapd/desktop`) so Nix-installed GUI apps find icons/`.desktop` files, plus a `targets.genericLinux.gpu` module and NixGL wrappers for 3D acceleration on Ubuntu. Flakes are "experimental in upstream Nix but stable in Determinate Nix" (Determinate docs); community adoption is heavy ("Nix users have overwhelmingly adopted flakes"). The honest caveat, well documented by practitioners, is that flakes have rough edges (jvns.ca's "Some notes on nix flakes" documents inscrutable errors; jade.fyi's "Flakes aren't real and cannot hurt you" argues flakes should be a thin entry point with most logic in ordinary Nix modules).
 
**3. What Nix cannot cleanly do on Ubuntu (so it needs a system layer).** home-manager is *user-scoped* and unprivileged; it cannot install apt packages, swap the kernel (HWE/mainline), edit `/etc/default/grub` to add `i915.enable_psr=0`, install proprietary drivers into the FHS, or set **system** (GDM/root) settings. The community pattern is explicit: "Use APT for system packages and dependencies" (dev.to APT cheatsheet). GNOME *user* settings, by contrast, **can** be done in Nix via home-manager's `dconf.settings` module (`dconf2nix` converts `dconf dump` output to Nix), and home-manager can define **user** systemd services (`systemd.user.services`) — which is exactly what the Duo scripts need.
 
**4. The Zenbook Duo module requirements (from alesya-h's README).** `alesya-h/zenbook-duo-2024-ux8406ma-linux` (≈118 stars, 29 forks, actively maintained) ships a `duo` script. Features and their dependencies:
- **brightness sync** and **battery limiter** — work on "any" desktop; brightness needs root (author uses a `NOPASSWD` sudo hack for `/usr/bin/env`).
- **automatic bottom-screen on/off** (GNOME) — needs `gnome-monitor-config`, `usbutils` (`lsusb`), `inotify-tools` (`inotifywait`); run `duo watch-displays` at GNOME session start. Manual: `duo top|bottom|both|toggle`.
- **automatic rotation** (GNOME) — needs `iio-sensor-proxy` (`monitor-sensor`); run `duo watch-rotation` at session start.
- **touch/pen panel mapping** (GNOME 46+) — `duo set-tablet-mapping` writes dconf; needs a patched Mutter (GNOME MR 3556) and libwacom (PR #640), both now merged upstream.
- `Fmstrat/zenbook-duo-linux` is the systemd-service-based alternative. Both are ordinary git repos with a script + services — ideal to **vendor as a pinned git submodule** or a pinned flake input, run via home-manager `systemd.user.services`, with dependency packages installed by the system (apt) layer.
**5. The alternatives, evaluated.**
- **chezmoi** (v2.71.1; ~20.7k stars per dotfiles.github.io) — excellent, mature, Go single binary, one-line bootstrap `sh -c "$(curl -fsLS https://get.chezmoi.io)" -- init --apply $USER`, templating via `.chezmoidata`/`.tmpl`, `run_once_`/`run_onchange_` scripts (great for apt), first-class secrets (age/gpg/git-crypt + password managers). **But** it manages file *content*, not packages; you'd be *migrating away* from a working Nix setup for no net capability gain. Common 2025 pattern (mizchi, kergoth, Hoshock) is chezmoi *alongside* home-manager, not instead.
- **Ansible** (`ansible-pull`, roles, tags) — the strongest tool for the *system* layer (apt module, kernel, GRUB, services) and supports per-host via inventory/tags, but it's heavier and re-introduces imperative YAML for the user layer you already have declaratively in Nix.
- **GNU Stow / yadm / dotbot / bare git** — simplest symlink managers; no package management, no real per-host logic beyond scripting. A step *backwards* from your flake.
- **Ubuntu-native (autoinstall/subiquity + cloud-init, `dconf dump/load`, apt manifest, Timeshift)** — autoinstall (Ubuntu desktop ≥23.04, YAML/cloud-init, `late-commands` run as root) is great for *unattended OS installs* but is machine-provisioning, not day-to-day config, and is finicky (24.04 user-data detection bugs reported). Worth keeping only as an *optional* accelerator, plus **Timeshift** for pre-change snapshots.
**6. Determinate installer note (important, dated).** The Determinate Nix Installer (`curl -fsSL https://install.determinate.systems/nix | sh -s -- install`) is fast, cross-platform (incl. WSL2), stable-flakes-by-default, with a clean uninstaller. **However, Determinate announced that in early 2026 it will stop distributing *upstream* Nix and install only *Determinate Nix* (proprietary distribution); the `--prefer-upstream-nix` flag will lose effect.** If you want plain upstream Nix, use the official installer or pin an older installer; if you're happy with Determinate Nix, the DS installer remains the smoothest path.
 
---
 
## Details: The Recommended System (one coherent design)
 
**One repo, three layers, host-selected.** `dome` becomes a single flake with:
1. **User layer (Nix / home-manager, flake-based)** — your shell, editor, terminal tooling, CLI packages, fonts, GNOME *user* dconf, and *user* systemd services. This is the evolution of what you already have.
2. **System layer (idempotent shell, invoked by `sudo`)** — a small, reviewable `system/` tree of bash scripts (driven by a `Makefile`/`install.sh`) that runs apt, installs the HWE kernel, edits GRUB, installs drivers, and writes GDM/system-level settings. Deliberately **not** Nix, because these need root + FHS + Ubuntu's own kernel/driver machinery.
3. **Host selection** — `hosts/<hostname>/` picks which optional modules (e.g., `zenbook-duo`) are enabled for both layers.
This keeps the declarative Nix core you already invested in, adds only the minimal imperative glue Ubuntu genuinely requires, and makes the Duo bits a clean opt-in.
 
### (a) Target repo structure
 
```
dome/
├── flake.nix                    # inputs: nixpkgs, home-manager, sops-nix, (optional) zenbook-duo input
├── flake.lock
├── install.sh                   # single-command bootstrap (curl|sh friendly): system layer → nix → user layer
├── Makefile                     # `make system`, `make home`, `make duo`, `make all`, `make update`
├── hosts/
│   ├── generic/
│   │   └── default.nix          # non-Duo machine: imports common home modules only
│   └── zenbook-duo/
│       └── default.nix          # imports common + modules/zenbook-duo (user side)
├── home/
│   ├── common.nix               # shell/editor/terminal/fonts/git/utils — everything portable
│   ├── shell.nix                # zsh + oh-my-zsh + starship (migrated from home.nix)
│   ├── editor.nix               # neovim/tmux dotfiles (NEW — currently missing)
│   ├── gnome.nix                # dconf.settings user-level GNOME tweaks (dconf2nix output)
│   └── langs/                   # renamed from modules/ (language dev envs)
│       ├── python.nix
│       ├── node.nix
│       ├── java.nix
│       └── ai.nix
├── modules/
│   └── zenbook-duo/
│       ├── default.nix          # systemd.user.services for `duo watch-displays` & `duo watch-rotation`,
│       │                        #   dconf tablet-mapping, references vendored script
│       └── vendor/              # pinned copy OR git submodule of alesya-h duo script
├── system/                      # SYSTEM LAYER (bash, run as root) — NEW
│   ├── common/
│   │   ├── apt-packages.sh      # base apt packages (build-essential, curl, git, etc.)
│   │   ├── hwe-kernel.sh        # install linux-generic-hwe-24.04 (or mainline)
│   │   ├── grub.sh              # add/remove kernel params in /etc/default/grub, update-grub
│   │   └── gdm-gnome.sh         # system-level GNOME/GDM settings (dconf system db)
│   └── zenbook-duo/
│       ├── apt-packages.sh      # gnome-monitor-config, usbutils, inotify-tools,
│       │                        #   iio-sensor-proxy, python3-pyusb
│       ├── grub.sh              # ensures i915.enable_psr=0 present
│       └── sudoers-brightness.sh# NOPASSWD rule so `duo` can set brightness (Duo-only)
├── secrets/                     # sops-nix age-encrypted files (safe to commit)
│   └── secrets.yaml
├── user-config.nix              # git-ignored: name, email, hostProfile, lang toggles
└── user-config.template.nix
```
 
**Mapping your current files:** `home.nix` → split into `home/common.nix` + `home/shell.nix`; `modules/*.nix` → `home/langs/*.nix` (kept as-is, just relocated); `user-config.nix`/template kept (add a `hostProfile = "generic" | "zenbook-duo"` field); `bootstrap.sh` logic → folded into `install.sh` + `system/` scripts. Nothing of value is dropped.
 
### (b) Bootstrap flow on fresh Ubuntu 24.04
 
Single command from the repo (after `git clone https://github.com/JowiAoun/dome ~/.dotfiles && cd ~/.dotfiles`):
 
```
./install.sh            # or: make all
```
 
`install.sh` does, in order:
1. **Detect host** — read hostname; if it matches `zenbook-duo` (or pass `--host zenbook-duo`), select the Duo profile. Persist choice to `user-config.nix`.
2. **System layer (sudo)** — run `system/common/*.sh`, then (if Duo) `system/zenbook-duo/*.sh`:
   - `apt update` and install base packages; if Duo, also `gnome-monitor-config usbutils inotify-tools iio-sensor-proxy python3-pyusb`.
   - Install HWE kernel: `apt install linux-generic-hwe-24.04` (get 6.14+; if you need the newer backport/mainline, use `bkw777/mainline` — noted with its caveat that mixing beta repos can pull incompatible `libssl3`/`libc6`).
   - GRUB: idempotently ensure (Duo only) `i915.enable_psr=0` in `GRUB_CMDLINE_LINUX_DEFAULT`, then `update-grub`. On generic machines this line is absent.
   - Drivers + GDM/system GNOME settings as needed.
   - **Take a Timeshift snapshot first** so kernel/GRUB changes are reversible.
3. **Install Nix** — official installer for plain upstream Nix, *or* Determinate installer if you accept Determinate Nix (see dated note above). Enable `experimental-features = nix-command flakes`.
4. **User layer** — `nix run home-manager/master -- switch --flake .#$(hostname)` (or `.#zenbook-duo`). This installs shell/editor/terminal/CLI/fonts, writes user dconf, and — if Duo — installs the two `systemd.user.services`.
5. **Optional Duo module** — the `duo` script is a **pinned git submodule** (or pinned flake input) under `modules/zenbook-duo/vendor/`; home-manager wires `systemd.user.services.duo-displays` (`ExecStart=… duo watch-displays`) and `duo-rotation` (`… duo watch-rotation`) with `WantedBy = ["graphical-session.target"]`, and applies the tablet-mapping dconf. A reboot picks up the new kernel and GRUB params.
A `curl … | sh` one-liner can wrap steps by cloning first (`bootstrap.sh` that clones then calls `install.sh`), but prefer `git clone + ./install.sh` so the system-layer scripts are reviewable before running as root.
 
### (c) How optional/machine-specific modules are toggled
 
Use an **explicit per-host flake output keyed on the real hostname**, replacing the current `$USER`-string approach:
 
```nix
homeConfigurations = {
  generic      = mkHome { host = "generic"; };
  zenbook-duo  = mkHome { host = "zenbook-duo"; };
};
```
`mkHome` imports `./hosts/${host}/default.nix`, which imports `home/common.nix` plus (only for the Duo host) `modules/zenbook-duo`. Selection = `home-manager switch --flake .#zenbook-duo` vs `.#generic`. The system layer mirrors this: `install.sh` runs `system/zenbook-duo/*` only when the Duo profile is chosen. Result: a brand-new non-Duo laptop is set up with `.#generic` and never touches any Duo package, service, GRUB param, or sudoers rule. Keep `user-config.nix.hostProfile` as the single source of truth so both layers read the same toggle. (Also make the flake pure: replace `builtins.getEnv "USER"` with an explicit `username` in `user-config.nix`, and consider `flake-utils`/`forAllSystems` instead of hardcoding `x86_64-linux`.)
 
### (d) Secrets
 
- **Do not** put unencrypted secrets in any tracked `.nix` file — the NixOS wiki warns flake contents are copied to the world-readable Nix store.
- **Recommended: `sops-nix`** — add it as a flake input, keep an age key on each machine (outside the repo), commit `secrets/secrets.yaml` encrypted; home-manager decrypts to `~/.config/…` at activation. Good for tokens, API keys, and non-key credentials.
- **SSH private keys / git credentials**: keep the private key material *out* of the repo entirely (generate per-machine, or provision from `sops`-encrypted blobs). Public config (`~/.ssh/config`, `git` user/signing settings) lives in home-manager. This matches the "one layer owns each file" discipline seen in mizchi's chezmoi+home-manager setup.
### (e) Migration steps (ordered; ~1–2 focused evenings)
 
1. **Make the flake pure and host-based (½–1 h).** Add `hostProfile` to `user-config.nix`; replace `builtins.getEnv "USER"` with explicit `username`; add `homeConfigurations.generic` and `.zenbook-duo` outputs via a `mkHome` helper. Keep old username aliases temporarily for Codespaces/WSL back-compat.
2. **Reorganize without behavior change (1 h).** Move `home.nix` logic into `home/common.nix`+`home/shell.nix`; move `modules/*` → `home/langs/*`. Run `home-manager switch --flake .#generic` to confirm parity on your current machine.
3. **Add the missing user config you expect (1–2 h).** Port your editor/terminal dotfiles into `home/editor.nix` (Neovim/tmux) and capture GNOME look-and-feel with `dconf dump` → `dconf2nix` → `home/gnome.nix`.
4. **Create the system layer (1–2 h).** Write `system/common/*.sh` (apt base, HWE kernel, GRUB helper that only *adds params it's told to*, GDM). Make each script idempotent (grep-before-append). Add `Makefile` targets and `install.sh` orchestration + Timeshift snapshot.
5. **Add the Duo profile (1 h).** Add `modules/zenbook-duo` (submodule vendor of alesya-h `duo`; `systemd.user.services`; tablet dconf) and `system/zenbook-duo/*` (apt deps, `i915.enable_psr=0`, brightness sudoers). Wire it only into `hosts/zenbook-duo`.
6. **Add secrets (½ h) and test (½ h).** Add `sops-nix`; then dry-run in a VM or on a spare user: `.#generic` on a clean Ubuntu, then `.#zenbook-duo` on the laptop.
### (f) Keeping the Duo scripts updated without breaking other machines
 
- **Pin, don't float.** Vendor alesya-h's `duo` as a **git submodule at a specific commit** (or a flake input with a locked rev). Update deliberately: `git submodule update --remote` (or `nix flake update zenbook-duo`), review the diff, test on the Duo, then commit the new pin.
- Because the Duo code is **only imported by `hosts/zenbook-duo`**, updating or even breaking it **cannot affect `.#generic`** machines — they never evaluate it.
- Track upstream by watching both `alesya-h/zenbook-duo-2024-ux8406ma-linux` and `Fmstrat/zenbook-duo-linux`; keep the systemd-based Fmstrat variant behind a second boolean if you ever want to swap implementations.
- Keep the GRUB param and apt deps in the `system/zenbook-duo` scripts so a Duo re-provision is one `make duo` away, and record the exact kernel version that worked in a comment for rollback via Timeshift/GRUB's kept old kernels.
### (g) Day-2 operations
 
- **Add a new machine:** install Ubuntu → `git clone` → `./install.sh --host generic` (or add a new `hosts/<name>` if it needs bespoke config). One command; no Duo baggage.
- **Sync changes between machines:** edit in the repo, `git push`; on each machine `git pull && home-manager switch --flake .#$(hostname)`; re-run `make system` only when the system layer changed. `nix flake update` bumps pinned inputs.
- **Test changes safely:** home-manager keeps generations — `home-manager generations` and roll back by activating an older one; use `-b backup` on switch (as your current bootstrap already does) to sidestep file conflicts. Take a **Timeshift** snapshot before any `make system` run (kernel/GRUB/apt). Optionally build a throwaway VM to validate `.#generic` end-to-end before touching real hardware.
---
 
## Recommendations (staged)
 
1. **Now:** Do migration steps 1–3 (purity + host layout + port editor/GNOME config). This alone modernizes the repo and lets `.#generic` fully reproduce your shell/editor/terminal/aesthetics on Ubuntu 24.04. *Benchmark to proceed:* `home-manager switch --flake .#generic` reproduces your environment on the Duo with no manual fix-ups.
2. **Next:** Build the `system/` layer (step 4) and install the HWE kernel + (Duo) `i915.enable_psr=0`. *Benchmark:* clean boot on 6.14+; no screen-flicker/PSR artifacts.
3. **Then:** Add `hosts/zenbook-duo` + the vendored `duo` submodule + apt deps (step 5). *Benchmark:* docking/undocking the keyboard toggles the bottom screen automatically; rotation and brightness sync work.
4. **Finally:** Add `sops-nix` (step 6) and, only if you'll reinstall the OS often, an *optional* Ubuntu **autoinstall** YAML to pre-seed partitions/kernel.
**Decision thresholds that would change this recommendation:**
- If you decide you no longer want to write Nix at all → switch the *user* layer to **chezmoi** (keep the same `system/` bash layer and `hosts/` toggle); it's the lowest-friction non-Nix option and is very mature.
- If you start managing *many* machines or servers, or want the system layer declarative too → adopt **Ansible** for the system layer (roles+tags mirror `system/common` vs `system/zenbook-duo`), keeping home-manager for the user layer.
- If you conclude Ubuntu-specific driver/kernel wrangling is more pain than it's worth and you don't need Ubuntu specifically → **NixOS** would make the *entire* stack declarative (system + user + Duo, including the sudoers/brightness rule the alesya-h README already documents for NixOS). You've chosen Ubuntu, so this stays a noted trade-off, not a recommendation.
---
 
## Caveats
 
- **Determinate installer change is imminent and material:** from early 2026 the Determinate Nix Installer installs *Determinate Nix* (proprietary distribution) and drops upstream Nix; `--prefer-upstream-nix` will stop working. Choose the official installer if you want plain upstream Nix. (Determinate blog, "Dropping upstream Nix from Determinate Nix Installer.")
- **Flakes are still officially "experimental" in upstream Nix** (stable only in Determinate Nix). They work well and are near-universal in practice, but expect occasional opaque errors (documented by jvns.ca and others). Keeping most logic in ordinary Nix modules with a thin `flake.nix` (per jade.fyi) reduces pain.
- **Duo panel/tablet mapping depends on GNOME 46+ with patched Mutter/libwacom** (GNOME MR 3556, libwacom PR #640). Both are merged upstream, but on Ubuntu 24.04's shipped GNOME you may need a newer GNOME/Mutter (or a backport) before `duo set-tablet-mapping` fully works; brightness sync and battery limiting work regardless of DE.
- **Brightness control needs root**; the upstream author's approach is a `NOPASSWD` sudoers rule (documented for NixOS as `security.sudo.extraRules`). On Ubuntu, scope this narrowly in `system/zenbook-duo/sudoers-brightness.sh` and understand the security trade-off before enabling.
- **HWE vs mainline kernel:** `linux-generic-hwe-24.04` is the safe route. `bkw777/mainline` can install newer kernels but its own README warns that pulling from beta repos can drag in incompatible `libssl3`/`libc6`; prefer HWE unless a specific Duo fix requires mainline.
- **Nix GUI apps on Ubuntu need `targets.genericLinux.enable = true;`** (and the GPU/NixGL handling) for icons and 3D acceleration; without it, Nix-installed GUI apps may show no icons or lack acceleration. Many system apps are better left to apt/Snap/Flatpak.
- **Ubuntu autoinstall is fiddly on 24.04** (community reports of user-data detection and password-setting issues); treat it as an optional accelerator, not a dependency.
- The `dome` repo is small and personal (1 star); this plan is based on its *actual* current contents as read from GitHub on the research date, not on assumptions — verify each file path still matches before executing the migration, since the repo may change.