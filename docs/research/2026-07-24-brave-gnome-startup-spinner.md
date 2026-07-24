# Brave on GNOME 46 Wayland: the busy cursor and the dead dash icon

Point-in-time investigation, 2026-07-24, on the UX8406MA (Ubuntu 24.04, GNOME 46,
Wayland, Dash to Panel). Written up because almost every intuitive explanation
here is wrong, and each wrong one cost a round of testing.

## TL;DR

Two *separate* bugs presented as one symptom ("Brave spins for ~10s and I can't
click its dash icon"):

| # | Symptom | Cause | Status |
|---|---------|-------|--------|
| 1 | Dash icon ignores clicks for ~15s | `StartupNotify=true` parks the `ShellApp` in `STARTING`; Dash to Panel only offers minimise/activate once `state == RUNNING` | **Fixed** — `StartupNotify=false` on every Chromium launcher (`modules/apps.nix`) |
| 2 | Spinning "busy" cursor over the panel for ~15s | Brave orphans xdg-activation tokens; mutter shows `META_CURSOR_BUSY` while any startup sequence is pending, and they only expire at mutter's 15s timeout | **Not fixed** — upstream Brave/Chromium bug, cosmetic |

Bug 2 is cosmetic: the window is on screen and usable at ~300ms throughout.

## Numbers

Measured on this machine, not taken from documentation.

- Brave's window maps in **~300–340ms** — identical from a terminal, from the
  dash, with the real 219MB profile, and with our `--enable-features` flags. Brave
  was **never** slow. Every "it takes 10 seconds to open" instinct was wrong.
- The `ShellApp` reaches `state=RUNNING` with its window bound **2ms** after
  `window-created`. Window→app association was never broken either.
- The busy cursor runs **717ms → 15958ms = 15.24s**, which is mutter's
  `STARTUP_TIMEOUT_MS` (15s). 891 cursor-change events at ~17ms = the 60fps
  animation of the watch cursor.
- The cursor turns busy when Brave **requests its first activation token**, not
  when GNOME launches it. Two independent traces agree: cursor at 717ms vs window
  at 725ms (8ms apart); Wayland `get_activation_token` at +324ms vs `set_app_id`
  at +337ms (13ms apart).

## Why only Brave

`NIXOS_OZONE_WL` is unset, so every Electron app here (Discord, Joplin, VS Code,
drawio, bruno) defaults to **X11** and never touches xdg-activation. Brave is the
only Chromium app on **Wayland**, because upstream Chromium flipped its default.
That is the entire reason Discord and Joplin never showed the symptom — not, as
first assumed, that they ship no `StartupNotify`.

## Orphan tokens track STARTUP SPEED, not profile content

The token accounting, `--user-data-dir` copies of the real profile:

| Profile | minted | used | orphans |
|---|---|---|---|
| Clean, with or without a URL argument | 2 | 2 | 0 |
| Real profile, with or without a URL argument | 3 | 1 | 2 |
| Real profile, as launched from the dash | 4 | 1 | 3 |
| Real profile, `--disable-extensions` | 4 | 1 | 3 |
| Real profile, `Sessions` removed | 3 | 1 | 2 |
| Real profile, `Preferences` removed | 5 | 1 | 4 |
| Real profile, later the same day (warm cache, smaller session) | 3 | 3 | **0** |

Not extensions, not session restore, not `Preferences` — and only ever **one**
window. Chromium re-requests focus while starting and uses only the last token;
the slower the start, the more spares it orphans. A fast start orphans none.

**Consequence:** the spinner comes and goes on its own. It vanished late on
2026-07-24 purely because the page cache was hot after ~30 launches and the
session file had shrunk. Expect it back on the first launch after a reboot. If
you are chasing this again, measure orphans, not wall-clock:

```bash
WAYLAND_DEBUG=1 brave-browser --user-data-dir=/tmp/x >log 2>&1
grep -c 'get_activation_token' log      # minted
grep -c 'xdg_activation_v1#[0-9]*\.activate(' log   # used; difference = orphans
```

## Why X11 is not the answer

`--ozone-platform=x11` removes the spinner completely (no xdg-activation exists),
and at 1920x1080 scale-1 with fractional scaling off it costs nothing visually.
It was still rejected, because it breaks per-app window identity:

| Launch | window class | GNOME maps it to |
|---|---|---|
| Web app alone, X11 | `notion` | `notion.desktop` OK |
| Web app alone, Wayland | `brave-www.notion.so__-Default` | `notion.desktop` OK |
| Web app **while Brave runs**, X11 | `Brave-browser` | `brave-browser.desktop` WRONG |
| Web app **while Brave runs**, Wayland | `brave-www.notion.so__-Default` | `notion.desktop` OK |

Wayland sets `app_id` **per window**, so Brave can label an `--app` window even
though it shares one process with the browser. X11's `WM_CLASS` is **per
process**, fixed by whichever Brave started first — and `--class` is ignored on
handoff (measured, both with and without it). It breaks both ways: launch a web
app first and the *browser's* window lands under the web app's icon.

The two cannot be split: all Brave windows share one profile, so a second launch
always hands off to the running process, and that process's platform wins. The
only way to have both is a separate `--user-data-dir` per web app, which costs
separate logins, cookies, extensions and sync — rejected as not worth it.

## Dead ends, so nobody repeats them

- **`StartupNotify=false` does not stop the cursor.** It fixes bug 1 only.
  Verified: with it false, `XDG_ACTIVATION_TOKEN` is absent from Brave's
  environment (so GNOME creates no launch sequence at all) and the cursor still
  spins its full 15s. The sequences come from *Brave*, not from the launch.
- **Brave's bash wrapper is not the cause.** `/usr/bin/brave-browser-stable`
  ends in `"$HERE/brave" "$@" || true` — it forks and waits rather than
  `exec`ing, so `GIO_LAUNCHED_DESKTOP_FILE_PID` names the wrapper while the
  window belongs to a different pid. Plausible, and wrong: an `exec`-ing
  replacement wrapper with identical environment changed nothing.
- **Dash to Panel is not involved.** It contains no startup-sequence or cursor
  code at all. Its click handler simply acts on `this.app`'s window list.
- **The AppArmor conflict is a real bug but costs ~0ms** — see below. Fixing it
  did not shorten the spinner by a millisecond.

## Related but separate: the AppArmor profile conflict

Found while investigating, fixed in `system/85-apparmor-userns.sh` (commit
`aeab79b`). Ubuntu's `apparmor` package ships `/etc/apparmor.d/brave` and Brave's
own `.deb` installs `/etc/apparmor.d/brave-browser-stable`; both attach
`/opt/brave.com/brave/brave`. AppArmor refuses to choose, logs `conflicting
profile attachments`, and leaves Brave **unconfined** — which then gets
transitioned into the restrictive `unprivileged_userns` profile and denied
`CAP_SYS_ADMIN`, so Chromium's namespace sandbox fails and it silently falls back
to the setuid one. 179 audit events in one day.

Brave's postinst has a guard meant to prevent exactly this, but it is dead code:
it tests `[ "brave-browser-stable" = "google-chrome-stable" ]`, which is never
true, and only ever looks for `/etc/apparmor.d/chrome`.

## Technique worth reusing: reading GNOME Shell's own state

Black-box guessing burned several rounds. What finally settled it was querying
the shell directly. `org.gnome.Shell.Eval` is disabled unless unsafe mode is on
(Alt+F2 -> `lg` -> `global.context.unsafe_mode = true`, resets at logout):

```bash
ev() { gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval "$1"; }

# app state (0=STOPPED 1=STARTING 2=RUNNING) and whether a window is bound
ev 'let a=Shell.AppSystem.get_default().lookup_app("brave-browser.desktop");
    "state="+a.state+" nwin="+a.get_n_windows()'

# what GNOME thinks each window is
ev 'let wt=Shell.WindowTracker.get_default();
    global.get_window_actors().map(a=>a.meta_window).map(w=>{let ap=wt.get_window_app(w);
    return (w.get_wm_class()||"-")+" -> "+(ap?ap.get_id():"NONE");}).join(" ;; ")'

# log cursor changes with timestamps (BUSY is a distinct sprite/hotspot)
ev 'let ct=Meta.CursorTracker.get_for_display(global.display);
    ct.connect("cursor-changed", () => { let s=ct.get_sprite(), h=ct.get_hot();
    global._dbg.push(Date.now()+" "+(s?s.get_width()+"x"+s.get_height():"null")+" hot="+h[0]+","+h[1]); });'
```

Gotchas found the hard way: `global.display.set_cursor` is never called from JS
(mutter sets the busy cursor in C, so hooking it shows nothing);
`MetaStartupNotification` has no reachable accessor from JS, and constructing one
gives a fresh empty object; `Screenshot` and `Introspect.GetWindows` are both
denied; pointer warping is blocked on Wayland; and the busy cursor only applies
over shell chrome, so a launch measured with the pointer over a window records
zero cursor changes.

Also: `pkill -f brave` matches the agent's own command line and kills its shell.
Use `pkill -x brave`.
