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
>   the live-USB install gate. Day to day it keeps the bottom panel in step with the
>   keyboard (off while docked, back on when you lift it off) and makes the Fn/media
>   row work — see [duo/README.md](duo/README.md)
> - `hosts/` + `flake.nix` — per-machine home-manager profiles
>   (`home-manager switch --flake path:.#generic` or `path:.#zenbook-duo`)
> - `install.sh` — one-command setup on a fresh Ubuntu machine

## Quick Start — pick your machine's path

| Machine | Path |
|---------|------|
| GitHub Codespaces | Enable dotfiles (below) — `bootstrap.sh` runs automatically |
| WSL / existing Linux that already has (or wants only) Nix | `./bootstrap.sh` (interactive) |
| **Fresh Ubuntu LTS machine (24.04 or 26.04) — any hardware** | `./install.sh --host generic` |
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
The system layer accepts the two LTS releases it has been checked against,
**24.04 (noble)** and **26.04 (resolute)**. Interim releases and other distros
need `FORCE=1`: they are supported for nine months, which is shorter than the
gap between provisions of this machine. Non-Ubuntu distros: only
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
- **Claude Code**: AI coding assistant, from the official installer so it is
  always current and self-updating
- **skills** ([vercel-labs/skills](https://github.com/vercel-labs/skills)): the
  open agent-skills CLI. Upstream documents `npx skills …`; this installs it
  globally instead, so it is a real `skills` command that starts instantly and
  works offline. `skills find`, `skills add <source>`, `skills ls`,
  `skills update`. It is an npm package needing Node ≥ 22.20, so this module
  installs `nodejs_22` itself when `modules.node` is off — the same derivation,
  so enabling both gives one Node, not two
- **Claude Code keybindings** (`~/.claude/keybindings.json`): **Shift+Enter**
  inserts a newline. That needs a terminal that can encode a modified Enter —
  see the terminal module below
- **Claude Code defaults**: theme dark (so a fresh machine never opens on the
  theme picker), *Show tips* off, *Use auto mode during plan* off, and *Copy on
  select* off — in the fullscreen TUI Claude Code runs its own mouse selection,
  and highlighting anything replaced the clipboard. Ghostty's
  `copy-on-select = false` covers the terminal's own version of that.

  The first three are `settings.json` keys; `copyOnSelect` is not in that schema
  and lives in `~/.claude.json` with the app's auth and history. Both files are
  written by Claude Code constantly, so neither can be a home-manager symlink —
  that would make the target read-only and break the app. They are merged with
  `jq` instead, every other key passed through untouched, and only when the file
  does not already agree.

  These values are **declared, not seeded**: they are re-applied on each
  `make home`, so a `/config` change to one of them lasts until then. Seeding
  only-if-missing was tried first and does not work — Claude Code materialises
  its own defaults into `settings.json` as you use it, so the key is usually
  already there holding the value you wanted changed.

#### Terminal (always on, not part of `modules.apps`)
**Ghostty**, installed on every machine with a desktop — deliberately *outside*
the optional apps bundle, because it is what everything else here runs inside.

- Set as the **default terminal**, which is also what Ctrl+Alt+T opens
  (`gsd-media-keys` resolves the shortcut through
  `org.gnome.desktop.default-applications.terminal`), and what Nautilus's
  "Open in Terminal" uses. Turn that off with `modules.terminal.setDefault = false`
- Pinned to the dash; GNOME Terminal is left installed as a fallback
- Its terminfo is installed to `~/.terminfo`, because Ubuntu's ncurses has never
  heard of `xterm-ghostty` and without it every system tool (vim, htop, less)
  dies with "unknown terminal type" inside it

The reason it is Ghostty and not GNOME Terminal is Shift+Enter. VTE implements
neither the Kitty keyboard protocol nor `modifyOtherKeys`, so Shift+Enter and
Enter reach applications as the same bare CR and *nothing* can tell them apart.
That is still true on the newer LTS — checked by `strings` on both shipped
libraries, 0.76.0 on 24.04 and 0.84.0 on 26.04, neither of which mentions
either mechanism. Ghostty speaks the Kitty protocol, so the keypress arrives as
`CSI 13;2u` and Claude Code's binding fires.

#### Desktop Apps (`modules.apps = true`)
GUI software **plus the desktop wiring that makes it usable** — desktop entries,
the default browser, and the GNOME dash:

- **Brave** — pinned to the dash (in Firefox's old slot) and set as the default
  browser for `http`/`https`/`text/html`; the Firefox pin is removed (the snap
  itself is left installed)
- **Thunderbird** — pinned, and set as the default mail client for `mailto:`,
  `message/rfc822` (`.eml`) and `mid:`
- **Discord** — pinned to the dash
- **Joplin** — pinned to the dash
- **draw.io**, **LocalSend**, **Bruno**, **OBS Studio**, **Zoom** — installed,
  not pinned
- **Notion**, **YouTube Music** — pinned **web apps**, see below

Budget roughly **5 GiB** of disk for the set. To hold one back without
removing it from the module, name it in `appsSkip` — that is the same switch
the already-installed detection uses, so it also skips the pin and the desktop
entry:

```nix
appsSkip = [ "bruno" "obs-studio" "joplin" ];   # install later, keep the config
```

`appsSkip` lives in `user-config.nix`, which is gitignored and regenerated on a
fresh machine — so anything parked there is *held back on this machine only*
and installs normally on a clean run.

**Web apps.** Some services ship no Linux client at all: Notion publishes macOS
and Windows builds only (nixpkgs' `notion-app` is macOS-only, and
`notion-app-enhanced` is a third-party repackage rather than a Notion build),
and YouTube Music has never had a desktop app. For those the vendor's web app
*is* the Linux client, so the module writes a launcher that opens it with
`--app=`: its own window, no tabs or address bar, its own icon and dash pin,
using the normal browser profile so logins persist. It costs a `.desktop` file
and an icon, since the browser is already installed.

Two details that are easy to get wrong, both settled by measurement rather than
guesswork:

- **Window identity.** GNOME matches a window to its launcher via
  `StartupWMClass`. Chromium ignores `--class` on Wayland (an X11 flag) and
  derives the id from the URL — `brave-www.notion.so__-Default`, captured with
  `WAYLAND_DEBUG=1`. Get it wrong and the window shows a generic cog icon.
- **Window size.** An `--app=` window has no saved geometry the first time it
  opens, so Chromium falls back to a small default; `--start-maximized` fixes
  it.

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

### Renaming the machine

```nix
# user-config.nix
hostName = "LAPTOP-JA";   # empty (the default) leaves the current name alone
```

Edit the field, then apply with `sudo make system` or `./setup.sh`. There is no
prompt for it — renaming is a one-off, and `setup.sh` carries whatever is
already there through untouched. Renaming means three things, and doing only
the first is how machines end up half-renamed:

| | where | what it affects |
|---|---|---|
| static | `/etc/hostname` | `hostname`, mDNS `<name>.local`, shell prompts |
| pretty | `PRETTY_HOSTNAME` in `/etc/machine-info` | GNOME Settings → About "Device Name", the Bluetooth name |
| hosts | the `127.0.1.1` line in `/etc/hosts` | local name resolution — miss it and **every `sudo` prints "unable to resolve host" after a DNS timeout** |

The `/etc/hosts` edit keeps any other aliases on that line (and anything Docker
Desktop added), refuses to write a file that lost its `localhost` entry, and
leaves the previous copy at `/etc/hosts.dome.bak`.

Not to be confused with `hostProfile`, which selects `hosts/<name>/` — the
per-machine *configuration* profile, nothing to do with the machine's name.

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

### Claude Desktop

The Claude desktop app (Linux beta) is **on** by default. It is not a Nix
package — Anthropic publishes it through their own signed apt repository — so
`system/75-claude-desktop.sh` installs it at the root layer and it updates with
the rest of the system on `apt upgrade`.

The signing key's fingerprint is pinned and verified before the repository is
registered: downloading a key over TLS only proves it came from that host,
whereas a mismatch here fails loudly instead of silently becoming trusted for
every later upgrade.

It is **pinned to the dash** by the apps module, which is why that module has a
`systemPins` list: the app comes from apt rather than Nix, so it is pinned only
once the `.desktop` file is really on the machine (absent = quietly not pinned).
`install.sh` runs the system layer *before* home-manager, so on a clean
provision it is already installed by the time the pin is written. The lookup
tries the known filenames and then falls back to whichever system entry
actually launches `claude-desktop`, so a renamed entry in a future `.deb` still
gets found.

Turn it off with `claudeDesktop = false;`, or for one run:

```bash
sudo bash system/run.sh --no-claude-desktop
```

These switches live outside `modules` in `user-config.nix`, because the root
layer reads them with `sed` rather than through Nix:

```nix
dockerEngine = true;        # Docker Engine (CE)
dockerDesktop = false;      # Docker Desktop GUI
claudeDesktop = true;       # Claude desktop app (beta)
openWhispr = true;          # OpenWhispr dictation, from its GitHub release (~1 GB)
braveBrowser = true;        # Brave from Brave's apt repo, not nixpkgs
braveManagedPolicy = true;  # Leo, Wallet, Rewards, VPN, News, Web Discovery off
```

Each has a matching one-run override on `system/run.sh` — `--no-brave`,
`--no-brave-policy`, `--no-openwhispr`, `--no-claude-desktop`.

### Brave, and why it is not a Nix package

`flake.lock` freezes nixpkgs at whatever commit it was last bumped to, so every
Nix package here is exactly as old as that pin. For most tools that is a
feature. For a browser it is a liability: this machine sat on Brave 143 — a
Chromium seven months old — until sites began refusing it, and no amount of
`make home` could have changed that. Only `make update` moves the pin, and it
moves *everything* at once.

So Brave comes from Brave's own signed apt repository instead
(`system/78-brave.sh`), and **every `sudo make system` upgrades it to the newest
build Brave has published**. `braveBrowser = true;` (the default) turns it on,
and the apps module reacts by installing no Nix Brave, pinning the apt one
through `systemPins`, and pointing `$BROWSER` and the web app launchers at
`/usr/bin/brave-browser`.

Registering the repository is *not* enough on its own, which is the mistake the
first version of this made: nothing on an Ubuntu desktop runs `apt upgrade` on a
schedule, so "it will update with apt" quietly means "whenever someone
remembers". That is how a browser gets seven releases behind. The script now
refreshes Brave's index — and only Brave's, a one-second request rather than a
full `apt-get update` — and runs `apt-get install --only-upgrade` on every run,
reporting the version change.

### Brave's settings, as policy

`system/79-brave-policy.sh` writes `/etc/brave/policies/managed/dome.json`,
turning off **Leo** (the AI assistant), the **Wallet**, **Rewards/BAT**, the
**VPN** upsell, **Brave News** and **Web Discovery**.

Policy, not preferences, and the distinction is the whole point:

- The profile's `Preferences` file is the browser's own live state — it rewrites
  it on exit, so an edit there is either clobbered or fights the running browser.
  Policy is read fresh from `/etc` at every launch, applies to every profile, and
  shows in the UI as *managed by your organisation* with the control greyed out.
- **It survives updates.** Nothing in the file names a Brave version, a Chromium
  version or an install path, and Chromium *ignores* policy keys it does not
  recognise — so a key a future Brave retires becomes a silent no-op instead of
  an error. `/etc` is untouched by the `.deb`.
- It applies to **both** installs, since `/etc/brave/policies` is compiled into
  the binary — the apt Brave and the nixpkgs one alike.

Adding another setting is one line in the script. Check the spelling against the
shipped binary rather than a support page, because the polarity is not
consistent upstream (some keys are `*Disabled`, some `*Enabled`):

```bash
strings /opt/brave.com/brave/brave | grep -xE 'Brave[A-Za-z]+(Disabled|Enabled)'
```

`braveManagedPolicy = false;` removes the file again and hands the settings back
to the browser UI. Verify what is in force at `brave://policy`.

### OpenWhispr

`system/76-openwhispr.sh` installs
[OpenWhispr](https://github.com/OpenWhispr/openwhispr) — voice-to-text dictation
with local Whisper/Parakeet models — from the vendor's GitHub release, exactly
as their Linux docs prescribe (`apt install ./OpenWhispr-*.deb`, so the
`ydotool` and `libpipewire` dependencies resolve; `dpkg -i` would not).

It is in the root layer rather than `modules/apps.nix` because nixpkgs does not
have it (checked) and the vendor ships a `.deb` — which installs its own
`/usr/share/applications` entry, so it needs none of the desktop patching the
Nix apps require. It is **not pinned to the dash**: it is hotkey-driven.

Two details worth knowing:

- **It is a ~1 GB install** (a 433 MB `.deb`, `Installed-Size` ≈ 985 MB). The
  script checks free space twice — once before spending the download, once
  against the real `Installed-Size` before unpacking — and declines with a
  message rather than filling `/`.
- **Every run costs a few hundred bytes, not 433 MB.** electron-builder
  publishes `latest-linux.yml` beside the binaries; the script reads the version
  and sha512 out of it, compares with `dpkg --compare-versions`, and downloads
  only when something newer exists. That checksum is also verified before
  installing.

Their docs also list a paste helper as a post-install step — `xdotool` for X11,
`wtype` for Wayland — so both are installed. Without one, dictation silently
pastes nothing.

The launchers adapt on their own: the Wayland `app_id` prefix is the basename
of the binary Chromium was *started* as, so it derives from `browserBin` rather
than being hardcoded — `brave-www.notion.so__-Default` under nixpkgs,
`brave-browser-www.notion.so__-Default` under the .deb.

Order matters when switching an existing machine over. The system layer must
install Brave *before* home-manager drops the Nix copy:

```bash
sudo make system   # installs Brave from the apt repo
make home          # drops the Nix copy, repoints the web apps
```

`./install.sh` already runs the two in that order.

One caveat on the key pin. Anthropic documents Claude Desktop's fingerprint, so
`75-claude-desktop.sh` verifies against a published value. Brave publishes no
machine-readable fingerprint for its apt keyring — `brave.com/linux` points at
`brave.com/signing-keys`, whose static HTML contains none of the three keys the
keyring actually ships (checked). `78-brave.sh` therefore pins the fingerprint
*set* it observed, cross-checked against the signature on the live
`dists/stable/InRelease`. That is trust-on-first-use: it cannot prove the first
fetch was honest, but it turns any later key swap into a loud failure rather
than silent trust for every future upgrade.

### Reinstalling this machine

Most of a rebuild is already free: the repo is on GitHub and `./install.sh`
re-derives the rest. `migrate/` covers the narrow set of things it cannot —
what lives only on this disk.

```bash
make preflight-wipe DEST=/media/$USER/STICK   # read-only: what would be lost
make backup DEST=/media/$USER/STICK           # capture it, browsers closed
# … wipe, install, first boot …
bash /media/$USER/STICK/dome-backup/restore.sh
```

`--preflight-wipe` answers one question: *if this disk were erased in five
minutes, what would be gone that no clone could bring back?* Hard failures are
unrecoverable-after-the-fact (unpushed commits, a missing `user-config.nix`, a
destination on the disk being erased); warnings merely cost time. What it cannot
know — whether your only TOTP seed lives here — it names instead of pretending
to check.

`backup.sh` captures five things git cannot: `~/.ssh` and `~/.gnupg`, the
gitignored `user-config.nix`, the login keyring, the browser profiles, and
**`/etc/NetworkManager/system-connections`**. That last one is easy to forget
and the most annoying to lose: it is root-owned, so a `$HOME` backup misses it,
and without it you cannot get online on the fresh install to fetch anything
else. It needs sudo; if sudo is unavailable the script says plainly that WiFi
was not captured rather than failing silently.

Three refusals, all for the same reason — a backup you cannot restore is worse
than none, because you will not find out until it matters:

- a destination on the same physical disk as `/`
- Brave or Firefox running (their profiles are live SQLite; copying one open
  yields a profile that looks fine and is corrupt)
- any archive that does not read back after being written

**`restore.sh` is copied onto the media by `backup.sh`.** That is deliberate,
not duplication. The restore happens on a fresh install *before* the repo has
been cloned — you need the SSH key to clone over SSH — so a restore tool that
lived only in the repo could never run when it is needed. Splitting
`user-config.nix` into its own archive is part of the same bootstrap: it means
the home restore never creates `~/.dotfiles`, which would make `git clone`
refuse a non-empty directory.

Each restore phase is idempotent and logs why it is skipping, so re-running
after installing a missing app picks up what could not apply the first time —
Firefox's profile needs `~/snap/firefox` to exist, so `restore.sh --only
firefox` after the first launch finishes the job.

### Disk encryption (LUKS)

Nothing in dome can encrypt a disk. LUKS has to be created while the disk is
being partitioned — Ubuntu installer → **Advanced features… → Use LVM and
encryption** — and a running root filesystem cannot be retrofitted safely. What
dome does is close the two gaps the installer leaves behind.

**The passphrase is unrecoverable.** This is the part that catches people
arriving from Windows. BitLocker generates a recovery key *for* you and escrows
it to your Microsoft account, so you can look it up later. LUKS has no
equivalent: you choose the passphrase, it is never displayed again, and it
cannot be extracted from the disk — the master key is stored wrapped by an
Argon2id derivation of it, which is one-way. Forget it and the data is gone.
There is no support line and no backdoor.

So `./setup.sh` refuses to be quiet about it. When it detects that `/` sits on
dm-crypt (it walks the chain upward, so it still sees LUKS through LVM) it shows
a full-screen warning and then asks where to keep a header backup, storing the
answer as `luksHeaderBackupDir` in `user-config.nix`. On an unencrypted machine
— WSL, Codespaces, a generic box — it asks nothing.

`system/95-luks.sh` then runs last in the system layer, so its warning is still
on screen when the run ends. It is read-only unless `luksHeaderBackupDir` is
set, and never fails the run:

- **Single-keyslot volumes.** The installer enrols exactly one passphrase and
  stops. The script counts enabled keyslots (LUKS1 and LUKS2 dump formats
  differ) and, if there is only one, prints the `cryptsetup luksAddKey` command
  for the specific device. Put a long random string in that second slot and keep
  it in a password manager — that is your recovery key.
- **Header backups.** The LUKS header holds the wrapped master key in the first
  few MB of the partition. Corrupt it and the *correct* passphrase stops
  working. The script writes `luks-header-<uuid>.img`, `chmod 600`, and verifies
  it reads back as a valid header.

Two refusals worth knowing. It will not write the backup to the same physical
disk the header protects — you could never mount the filesystem holding it
without the header you are trying to recover — and it will not silently
overwrite an existing backup, because that file is a *snapshot* of the keyslots:
after a passphrase change the old file still opens the disk with the old
passphrase. Delete and re-take it when you change one.

The destination is read from `user-config.nix` rather than an environment
variable for the reason `lib.sh` documents: `sudo`'s `env_reset` would drop a
`LUKS_BACKUP_DIR=…` prefix, and a backup that silently never happens is worse
than none.

**On the Duo specifically:** the passphrase prompt runs in the initramfs, which
has no Bluetooth stack and no on-screen keyboard. The keyboard must be
physically attached at boot — detached, it is a Bluetooth device and you cannot
type the passphrase at all. Worth proving to yourself on the first boot rather
than discovering it later.

### Skipping the passphrase with the TPM (opt-in)

`system/96-tpm-unlock.sh` can enrol the encrypted root into the TPM so the disk
unlocks from the chip and no passphrase is typed at boot. It is **off by
default** and gated on `tpmAutoUnlock = true` in `user-config.nix`, because it is
a genuine trade-off: the disk stays encrypted against a pulled drive or a
powered-off theft, but anyone who can power the machine on reaches the login
screen without the disk passphrase. The passphrase keyslot is never removed, so
it remains the automatic fallback.

It uses **Clevis**, not `systemd-cryptenroll`. The systemd-native
`tpm2-device=auto` option is honoured only by `sd-cryptsetup`, which is not in
Ubuntu's `initramfs-tools` initramfs (Launchpad #1980018) — on stock Noble the
option is silently ignored and the disk still prompts. Getting it would mean
replacing `initramfs-tools` with dracut, a large change to the boot pipeline the
rest of this repo assumes; Clevis plugs into the initramfs Ubuntu already ships,
so `/etc/crypttab` is left untouched. The script installs the Clevis packages, a
small `tss-user` initramfs hook (24.04's `clevis-initramfs` omits the `tss` user
the TPM tooling drops to — without it the unseal fails and boot falls back to the
prompt), binds the volume to **PCR 7**, rebuilds the initramfs, and verifies the
result before you ever reboot.

PCR 7 measures Secure Boot state, so the binding survives ordinary signed kernel
and initramfs updates but re-locks after a Secure Boot or firmware-key change (a
BIOS `dbx` update, a MOK enrolment, or turning Secure Boot off). When that
happens you simply get the passphrase prompt again — expected and safe — and
re-enrol to capture the new state. The script prints the exact `clevis luks
unbind`/`bind` commands for both re-enrolling and turning it off. The enrol step
needs your existing passphrase, so on a non-interactive run it prints the one
command to run rather than failing.

### No icon flashing in the dash on copy/paste

Claude Code checks the clipboard on every paste to see whether you pasted an
image. On Wayland it reaches for `wl-clipboard`, and that used to make an icon
blink in the dash on every copy and paste.

GNOME 46 does not implement `wlr-data-control`, so `wl-paste`/`wl-copy` have no
headless way to read the clipboard. They map a real (1x1) toplevel purely to
receive a keyboard-focus serial — visible in `WAYLAND_DEBUG=1 wl-paste`:

```
-> xdg_toplevel@15.set_title("wl-clipboard")
-> wl_surface@13.attach(wl_buffer@18, 0, 0)   # mapped, so the dash draws it
   wl_keyboard@12.enter(...)                  # the serial it was after
-> xdg_toplevel@15.destroy()                  # ~20ms later
```

It never calls `set_app_id`, so the shell cannot match it to a `.desktop` and
draws a generic placeholder — the flash. `xclip` does the same job through
Xwayland with a window it never maps, so nothing is drawn.

`modules/ai.nix` therefore installs `xclip` and puts tiny `wl-paste`/`wl-copy`
shims in front of **Claude Code only**, via a `claude` shell function. They are
deliberately not installed into the profile: they cover just the flags Claude
Code passes, so they must not shadow the real `wl-clipboard` system-wide. With
no `DISPLAY` to borrow they hand back to the real tool — a brief window beats a
broken clipboard.

Installing `xclip` matters on its own: Ubuntu ships neither `xclip` nor
`wl-clipboard` by default (they arrive only as *Recommends* of packages like
`pass`), so without it Claude Code has no clipboard helper at all and pasting a
screenshot into it silently does nothing.

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
│   ├── ai.nix             # AI tools (Claude Code, skills CLI, keybindings)
│   ├── terminal.nix       # Ghostty + default-terminal wiring (not under apps)
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