# CLAUDE.md — agent guide for this repo

## Never write `cmd | grep -q` in a system script

`system/lib.sh` sets `pipefail`, and `grep -q` exits at the **first match** —
which can SIGPIPE a writer that still has output to produce. The pipeline then
returns 141, so **a successful match is reported as a failure**. It is a race
against the writer's buffering, not a size threshold: `apt-cache policy <pkg>`
prints six lines and still loses it.

This has already shipped twice (`system/25-memory.sh` silently skipped its whole
zram section; `system/20-kernel.sh` would have left a fresh machine on the GA
kernel). `shellcheck` and `nix eval` both pass on it, and the script still
exits 0 — it just does the wrong thing and logs a plausible reason.

Use the `out_matches` helper in `system/lib.sh`: capture the output first, then
match it. A herestring is backed by a temp file, so there is no writer left to
hang up on.

```bash
out_matches "$(lsblk -no TYPE --inverse "$src")" -x crypt     # not: lsblk … | grep -qx crypt
out_matches "$out" -E '^(Hit|Get):'                           # not: printf … | grep -qE …
[ -n "$(find "$d" -name foo)" ]                               # not: find … | grep -q .
```

Related helper: **`install_conf <path> <content>`** writes a config file only
when it differs, honours `DRY_RUN`, and returns 0 when it changed something —
so use `if install_conf …; then <reload>; fi` and reload only when needed. Both
helpers are covered by `tests/test-lib.sh`; run `make test` after touching
`lib.sh`.

## Never write a bare number into `dconf.settings`

Same failure shape as above — everything passes and the setting does nothing.
home-manager types a plain Nix integer as **int32**. If the GSettings schema
declares any other numeric type, dconf stores the value and `dconf read` shows it
back, but GSettings type-checks on read, **silently falls back to the schema
default**, and the app keeps its old behaviour. `nix build` passes, activation
passes, `dconf read` looks right, nothing warns.

Measured on `org.gnome.mutter check-alive-timeout`, whose schema type is `u`:

```bash
dconf write /org/gnome/mutter/check-alive-timeout 30000
gsettings get org.gnome.mutter check-alive-timeout   # -> uint32 5000   IGNORED
dconf write /org/gnome/mutter/check-alive-timeout "uint32 30000"
gsettings get org.gnome.mutter check-alive-timeout   # -> uint32 30000  applied
```

So check the type before writing the key, and wrap anything that is not `i`:

```bash
gsettings range <schema.id> <key>        # "type u" -> needs mkUint32
```

```nix
"org/gnome/mutter".check-alive-timeout = lib.hm.gvariant.mkUint32 30000;   # home.nix
```

The generated keyfile shows the difference directly — build both ways and grep
the `hm-dconf.ini` derivation: a bare `30000` is emitted as
`check-alive-timeout=30000` (untyped, so int32), `mkUint32 30000` as
`check-alive-timeout=@u 30000`.

`lib.hm.gvariant` also has `mkUint16/64`, `mkInt16/64`, `mkDouble`, `mkUchar`,
`mkArray`, `mkTuple`, `mkVariant`, `mkDictionaryEntry` — see
`modules/desktop-shell.nix`, which builds the `aa{sv}` app-grid layout by hand.

To verify after `make home`, read the key **both ways**. They must agree; if
`gsettings` still reports the old value, the type is wrong:

```bash
dconf read /org/gnome/mutter/check-alive-timeout      # what we wrote
gsettings get org.gnome.mutter check-alive-timeout    # what the app sees
```

The sibling trap, documented at the Tracker setting in `modules/desktop-shell.nix`:
the dconf **path** is not the schema id lowercased with slashes. `dconf.settings`
writes wherever it is told and never validates against a schema, so a wrong path
stores a value that simply nothing reads — and it looks identical to this one.

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

## Organising the "Show Apps" grid (folders + order)

When the user asks to **put an app in a folder**, "move \<X\> into \<folder\>",
reorder the app grid, or asks why a freshly-installed app is loose at the end of
the grid, edit **`modules/desktop-shell.nix`** — the *App grid organisation*
block in its `let` (gated on `modules.desktopShell.enable`, i.e. a GNOME host).
Do **not** reach for `gsettings`/`dconf` by hand.

- **`appFolders`** — one entry per grid folder (`id`, `name`, `apps`). To file an
  app, add its `.desktop` id to that folder's `apps` list. Folders use explicit
  app lists, never `categories`, so a newly-installed app is never auto-grouped.
- **`topLevel`** — the ordered list of items shown outside folders (the apps the
  user launches, then the folder ids). Add or reorder here to place a top-level
  app.
- **New apps land at the END of the grid on purpose**: anything not in a folder
  and not in `topLevel` is left off the layout, so GNOME appends it and the user
  can see it and decide where it belongs. That trailing spot is the intended
  "inbox", not a bug — file the app by editing the lists above.

This is **declarative and re-asserted on every `make home`**: organise in the
repo, never by dragging in GNOME (a drag-rearrange is wiped on the next switch).
The `app-picker-layout` dconf value is a GVariant generated from `topLevel` —
edit the Nix lists, not the dconf. Takes effect on `make home` / `setup.sh`; a
full grid rebuild happens at the next login if it looks half-updated.
