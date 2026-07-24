# CLAUDE.md — agent guide for this repo

Instructions for AI agents (Claude Code and the like) working in this dotfiles
repository. This file is loaded into agent context automatically, so keep it
short and factual. For a full tour, read `README.md`; the machine is configured
with Nix + home-manager (`home.nix`, `modules/`) plus imperative system steps in
`system/`.

## Making an installed program show up as a desktop app

When the user asks to **"make a desktop app"**, "add \<X\> to the launcher / app
grid", "make \<X\> show up when I search", or otherwise turn a program they
installed by hand into a first-class application, **use the `mkdesktop` helper** —
do not hand-write a `.desktop` file from scratch. That is the exact mistake this
tool exists to prevent (an invalid `Exec` is silently dropped from GNOME search).

- Source: `modules/mkdesktop.sh`. Installed on `PATH` as `~/.local/bin/mkdesktop`
  after `make home` (run it via `bash modules/mkdesktop.sh` if not yet installed).
- It applies to anything that did **not** come from `apt`/`.deb`, `snap` or
  `flatpak` — a downloaded binary, an AppImage, an extracted tarball. Those
  formats register their own launcher entry; a bare download ships none (or a
  broken one), so it never appears in search and only runs by double-clicking.

```bash
mkdesktop <path-to-binary> --name "<Display Name>" [--icon <file>] [--categories "Game;"]
```

`mkdesktop` writes a valid `~/.local/share/applications` entry with absolute
`Exec`/`Path`/`Icon`, auto-detects an icon sitting next to the binary, validates
the entry, and refreshes the app database so search picks it up immediately.

**Example** — an Obsidian AppImage the user downloaded to `~/Applications`:

```bash
mkdesktop ~/Applications/Obsidian.AppImage --name "Obsidian" --icon ~/Applications/obsidian.png
```

**The dash icon — the one thing `mkdesktop` cannot guess.** `StartupWMClass` is
the class the *running* window reports, and it is what makes the taskbar/dash show
the app's own icon instead of a generic placeholder. `mkdesktop` leaves it unset
and prints how to find it. If the user says the dash icon is wrong or generic
*while the app is open*, read the class off the live window and re-run with
`--wmclass`:

```bash
# Wayland:  WAYLAND_DEBUG=1 <binary> 2>&1 | grep -m1 set_app_id   # -> set_app_id("...")
# X11:      xprop WM_CLASS                                        # then click the window
mkdesktop <binary> --name "<Name>" --wmclass <value>
```
