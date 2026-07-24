# Research archive

Point-in-time research reports that fed the ZenDuo project (Ubuntu 24.04 dual boot on the
ASUS Zenbook Duo 2024 UX8406MA + the evolution of this repo). The **living plan** is
[`../PLAN.md`](../PLAN.md) — these files are kept as provenance and are not updated.

| File | What it is |
|------|------------|
| `2026-07-hardware-ubuntu-2404-ux8406ma.md` | Deep research: running Ubuntu 24.04 natively on the UX8406MA — kernel support matrix, community projects, feature-by-feature status |
| `2026-07-dome-repo-evolution.md` | Deep research: how to evolve `dome` (home-manager flake) into a hybrid user/system/host-profile setup |
| `2026-07-21-zenduo-master-plan-v1.0.md` | First frozen version of the master plan (superseded by `../PLAN.md`) |
| `2026-07-24-brave-gnome-startup-spinner.md` | Investigation: Brave's ~15s busy cursor and dead dash icon on GNOME 46 Wayland — two separate bugs, what was measured, and the dead ends |

Verification status of individual claims in these reports is tracked in the plan's §2
("Verified research baseline") — do not act on a claim from these files without checking
its verification tag there first.

The Brave/GNOME file is the exception to "deep research": it is a debugging log, and every
figure in it was measured on this machine rather than read anywhere. It also carries the
`org.gnome.Shell.Eval` recipes for reading GNOME's own app/window/cursor state, which are
worth reaching for before guessing at any future shell-behaviour bug.
