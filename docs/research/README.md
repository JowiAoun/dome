# Research archive

Point-in-time research reports that fed this repo's evolution. They are kept as
provenance and are not updated.

| File | What it is |
|------|------------|
| `2026-07-dome-repo-evolution.md` | Deep research: how to evolve `dome` (home-manager flake) into a hybrid user/system/host-profile setup |
| `2026-07-24-brave-gnome-startup-spinner.md` | Investigation: Brave's ~15s busy cursor and dead dash icon on GNOME 46 Wayland — two separate bugs, what was measured, and the dead ends |

The Zenbook Duo research (the hardware report, the dual-boot master plan, the
install checklist and the as-built log) moved with the rest of the Duo support to
[linux-on-zenbook-duo](https://github.com/JowiAoun/linux-on-zenbook-duo/tree/main/docs).

The Brave/GNOME file is a debugging log rather than "deep research": every figure
in it was measured on this machine rather than read anywhere. It also carries the
`org.gnome.Shell.Eval` recipes for reading GNOME's own app/window/cursor state, which
are worth reaching for before guessing at any future shell-behaviour bug.
