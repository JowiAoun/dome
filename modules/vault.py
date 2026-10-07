#!/usr/bin/env python3
"""vault: an encrypted folder at ~/Vault that locks itself and leaves no
trace of its files outside itself.

modules/vault.nix has the design. In short: gocryptfs keeps the files
encrypted in ~/.vault and shows them decrypted at a mount point under
/run/user, which ~/Vault links to. `vault guard` runs as a user service and
locks the vault when you go idle, lock the screen, suspend or log out.
`vault check` runs on a timer of its own, so if the guard misses something or
stops, the vault still locks and what it left behind still goes.

This program never writes a vault file name outside the vault: not to the
journal, not to a state file, not to a notification. Its messages carry
counts and program names only, and errors are logged by type alone, because
an error message can carry a file name.
"""

import contextlib
import ctypes
import fcntl
import functools
import getpass
import json
import os
import re
import resource
import shlex
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import traceback
import xml.etree.ElementTree as ET
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

USAGE = """\
usage: vault open [--no-window]   unlock it (creating it the first time) and show it in Files
       vault add <file>...        move files and folders in, leaving nothing behind outside
       vault close                close everything using it, then lock it
       vault status               say whether it is open and what is using it
       vault check                test every part, repair what it can, clear leftovers
       vault key                  show the master key again (asks the password)"""

HOME = Path.home()
UID = os.getuid()
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{UID}")
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")

# Every path can be moved with an environment variable. That is how this was
# tested against a throwaway vault without going near the real one.
CIPHER = Path(os.environ.get("VAULT_CIPHER") or HOME / ".vault")
LINK = Path(os.environ.get("VAULT_LINK") or HOME / "Vault")
MOUNT = Path(os.environ.get("VAULT_MOUNT") or RUNTIME / "vault")
STATE = Path(os.environ.get("VAULT_STATE") or RUNTIME / "vault-state")
# Kept across reboots, unlike STATE: the paused settings to put back, and the
# warnings, which must still be on screen after a crash or a logout.
PERSIST = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "vault"
SAVED = Path(os.environ.get("VAULT_SAVED") or PERSIST / "paused-settings.json")
IDLE_SECONDS = int(os.environ.get("VAULT_IDLE_SECONDS") or 15 * 60)

GUARD = os.environ.get("VAULT_GUARD_UNIT") or "vault-guard.service"
CHECK = "vault-check.service"
TIMER = os.environ.get("VAULT_TIMER_UNIT") or "vault-check.timer"

ROOTS = (str(MOUNT), str(LINK))
# Either root, as long as what follows ends the name: /run/user/1000/vault-state
# is not the vault.
VAULT_TEXT = re.compile("(?:%s)(?=$|[/\\s,;\"'<>&)\\]])" % "|".join(re.escape(r) for r in ROOTS))
SELF = os.path.realpath(__file__)
APPS = STATE / "apps.json"
OPENED = STATE / "opened.json"
HEALTH = STATE / "guard.json"
WARNINGS = PERSIST / "warnings.json"
# One line per warning, read by vault-banner.sh at the top of every new
# terminal. alarms.txt is written by vault-alarm.sh, which runs when this
# program could not.
WARNINGS_TXT = PERSIST / "warnings.txt"
ALARMS_TXT = PERSIST / "alarms.txt"
CHECKED = PERSIST / "check.json"
# A warning that stays true is shown again after this long.
REMIND = 4 * 3600

RECENT = DATA / "recently-used.xbel"
TEXT_EDITOR = DATA / "org.gnome.TextEditor"
THUMBNAILS = CACHE / "thumbnails"
DOCS = f"{RUNTIME}/doc/"

# Each recent list, and the program to close when it holds a vault file. None
# means read the program off the entry. Text Editor keeps a list of its own
# that GNOME's file history switch does not reach.
RECENT_LISTS = ((RECENT, None), (TEXT_EDITOR / "recently-used.xbel", "gnome-text-editor"))

# Where other apps keep a history of their own.
VLC = HOME / ".var/app/org.videolan.VLC/config/vlc"
LIBREOFFICE = CONFIG / "libreoffice/4/user"
AUDACITY = DATA / "Audacity/Audacity4"
AUDACITY_INI = CONFIG / "Audacity/Audacity4.ini"
XOURNALPP = CONFIG / "xournalpp/settings.xml"
XOURNALPP_NOTES = (CACHE / "xournalpp/metadata", DATA / "xournalpp/metadata")
BRAVE = CONFIG / "BraveSoftware/Brave-Browser"
# Brave's databases that keep a URL or a path as text: history and downloads,
# what the address bar learned from typing, and the most visited pages.
BRAVE_DATABASES = ("History", "Shortcuts", "Network Action Predictor", "Top Sites")
VSCODE = CONFIG / "Code"
# The file chooser's last folder, GTK 3 and 4 (the portal's chooser included),
# and Text Editor's last save folder.
FOLDER_KEYS = (
    "/org/gtk/gtk4/settings/file-chooser/last-folder-uri",
    "/org/gtk/settings/file-chooser/last-folder-uri",
    "/org/gnome/TextEditor/last-save-directory",
)
OOR = "http://openoffice.org/2001/registry"
XS = "http://www.w3.org/2001/XMLSchema"
XSI = "http://www.w3.org/2001/XMLSchema-instance"

# Switched off while the vault is open and put back when it locks, so no
# thumbnail of a vault file is ever made. GNOME's file history switch cannot
# be used the same way: turning it off makes the running GTK apps empty the
# whole history, which on this machine was 1,002 entries gone in under four
# seconds. The recent lists are handled by strip_recent instead.
PAUSED = {"/org/gnome/desktop/thumbnailers/disable-all": "true"}

# The desktop itself, and processes that only hold the vault open for someone
# else. Killing one of these closes far more than a vault file, and none of
# them has to die for the lock to work: once gocryptfs is gone, whatever they
# still hold stops reading. A Files window showing the vault goes empty and a
# terminal tab closes when its shell does.
KEEP_NAMES = {
    "systemd", "gnome-shell", "Xwayland", "nautilus", "ghostty",
    "dbus-daemon", "dbus-broker", "dbus-broker-launch", "wireplumber",
}
KEEP_PREFIXES = (
    "gnome-session", "gsd-", "gvfs", "xdg-", "tracker", "localsearch",
    "pipewire", "gocryptfs", "at-spi", "ibus",
)
# A recent-file entry names the command that opened it. These start some other
# program rather than being one, so they say nothing about what to close.
LAUNCHERS = {"flatpak", "env", "sh", "bash", "gio", "gtk-launch", "xdg-open"}
# Interactive shells ignore SIGTERM. SIGHUP is what closing the terminal sends.
SHELLS = {"bash", "zsh", "fish", "sh", "dash"}


def log(message):
    print(f"vault: {message}", file=sys.stderr, flush=True)


def die(message):
    log(message)
    sys.exit(1)


def failure(error):
    """An error by type and line only. A traceback would print its message,
    and that can be a vault path."""
    frame = traceback.extract_tb(error.__traceback__)[-1]
    return f"{type(error).__name__} at line {frame.lineno}"


def quietly(keep=False):
    """For guard callbacks: an error is logged and the guard carries on. keep
    is what a periodic GLib timer must return to stay scheduled."""
    def wrap(action):
        @functools.wraps(action)
        def run(*args):
            try:
                return action(*args)
            except Exception as error:
                log(f"{action.__name__} failed: {failure(error)}")
                with contextlib.suppress(Exception):
                    warn(f"guard-error:{action.__name__}", "Vault: part of the guard failed",
                         f"Its {action.__name__.replace('_', ' ')} step failed ({failure(error)}). "
                         "The 2-minute check covers for it.", incident=True)
                return keep or None
        return run
    return wrap


def send(title, body, critical=False, replace=None):
    """One desktop notification. Returns its id, so a later one can replace
    it, or None when none could be shown. A critical one stays on screen
    until it is dismissed."""
    args = ["notify-send", "-a", "Vault", "-p", "-u", "critical" if critical else "normal",
            "-i", "dialog-warning" if critical else "changes-prevent-symbolic"]
    if replace:
        args += ["-r", str(replace)]
    try:
        out = subprocess.run([*args, title, body], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return int(out) if out.isdigit() else None


def notify(title, body):
    send(title, body)


def write_atomic(path, data):
    """Swap in a new copy, keeping the old one's permissions: several of the
    files this edits are private (0600) to their app."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8", "surrogateescape"))
    with contextlib.suppress(OSError):
        os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)


def read_text(path):
    return path.read_text(encoding="utf-8", errors="surrogateescape")


def wait_for(condition, seconds):
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() > deadline:
            return False
        time.sleep(0.05)
    return True


class AppRunning(Exception):
    """A clean-up that has to wait for its app to close. An app writes its
    settings back out on exit, so editing them under it is undone."""


def attempt(report, label, action, *args):
    """Run one part of a lock, a check or a sweep on its own, so one failing
    leaves the others running. Adds (label, status, detail) to report:
    ok with a count of what it changed, later when its app is open, failed."""
    try:
        result = action(*args)
    except AppRunning as busy:
        report.append((label, "later", str(busy)))
        return None
    except Exception as error:
        log(f"{label}: failed ({type(error).__name__})")
        report.append((label, "failed", type(error).__name__))
        return None
    report.append((label, "ok", result))
    return result


def problems(report):
    return [label for label, status, _ in report if status == "failed"]


def counted(result):
    """A part that changed something returns how many things; True and False
    are answers, not counts."""
    return isinstance(result, int) and not isinstance(result, bool) and result > 0


# Warnings. Two kinds, both shown the same way:
#   a condition is something still wrong, such as a guard that will not start;
#     it clears itself when a check finds it working, and says so.
#   an incident is something that went wrong and was dealt with, such as a
#     crash the guard restarted from; it stays until you have seen it in
#     `vault check`.
# Each one is a critical notification, a line at the top of every new
# terminal (vault-banner.sh), and an entry in `vault check` and `vault status`.

@contextlib.contextmanager
def warnings_held():
    PERSIST.mkdir(parents=True, exist_ok=True)
    with open(PERSIST / ".warnings.lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def active_warnings():
    try:
        return json.loads(WARNINGS.read_text())
    except (OSError, ValueError):
        return {}


def save_warnings(warnings):
    if not warnings:
        WARNINGS.unlink(missing_ok=True)
        WARNINGS_TXT.unlink(missing_ok=True)
        return
    write_atomic(WARNINGS, json.dumps(warnings, indent=1))
    lines = sorted(warnings.values(), key=lambda w: w["since"])
    write_atomic(WARNINGS_TXT, "".join(
        f"{w['title']} (since {time.strftime('%a %H:%M', time.localtime(w['since']))})\n" for w in lines))


def warn(key, title, body, fixed=None, incident=False):
    """Raise a warning: notified at once, again every four hours while it
    lasts, and after any gap of ten minutes or more between checks, which is
    how one raised before a logout or a reboot reaches you after it."""
    log(f"WARNING {title}")
    with warnings_held():
        warnings = active_warnings()
        entry = warnings.get(key) or {"since": time.time(), "notified": 0, "id": None}
        entry.update(title=title, body=body, fixed=fixed or f"Fixed: {title.removeprefix('Vault: ')}.",
                     incident=incident)
        if time.time() - entry["notified"] >= REMIND:
            entry["id"] = shout(entry) or entry["id"]
            entry["notified"] = time.time()
        warnings[key] = entry
        save_warnings(warnings)


def shout(entry):
    return send(entry["title"], entry["body"] + "\n\nRun `vault check` in a terminal for details.",
                critical=True, replace=entry.get("id"))


def resolve(key):
    """A condition that works again: its warning goes, and the notification
    on screen is replaced with one saying it is fixed."""
    with warnings_held():
        warnings = active_warnings()
        entry = warnings.pop(key, None)
        if entry is None or entry.get("incident"):
            return
        save_warnings(warnings)
    log(f"fixed: {entry['title']}")
    send("Vault: fixed", entry["fixed"], replace=entry.get("id"))


def remind_all():
    with warnings_held():
        warnings = active_warnings()
        for entry in warnings.values():
            entry["id"] = shout(entry) or entry.get("id")
            entry["notified"] = time.time()
        save_warnings(warnings)


def take_incidents():
    """Hand back the incidents and clear them: `vault check` prints them, and
    seeing them there is what acknowledges them."""
    with warnings_held():
        warnings = active_warnings()
        seen = {k: w for k, w in warnings.items() if w.get("incident")}
        save_warnings({k: w for k, w in warnings.items() if not w.get("incident")})
    return seen


def alarms():
    """unit to message, from vault-alarm.sh."""
    try:
        lines = read_text(ALARMS_TXT).splitlines()
    except OSError:
        return {}
    return dict(line.split("\t", 1) for line in lines if "\t" in line)


def clear_alarm(unit):
    remaining = {u: m for u, m in alarms().items() if u != unit}
    if remaining:
        write_atomic(ALARMS_TXT, "".join(f"{u}\t{m}\n" for u, m in remaining.items()))
    else:
        ALARMS_TXT.unlink(missing_ok=True)


# What each part failing means, for its warning: the trouble, then what it
# can leave you with.
PARTS = {
    "~/Vault link and ~/.hidden": ("~/Vault could not be set up",
                                   "~/Vault may be missing, or show in your home folder."),
    "missed locks": ("the lock check failed",
                     "The vault may stay open after the screen locks or you go idle."),
    "reading Recent files": ("Recent files could not be read at lock",
                             "Apps that showed vault files may have stayed open."),
    "reading Flatpak documents": ("Flatpak documents could not be read at lock",
                                  "Flatpak apps such as VLC may have stayed open on a vault file."),
    "finding programs": ("programs using the vault could not be found",
                         "Windows showing vault files may have stayed open after the lock."),
    "closing programs": ("programs using the vault could not be closed",
                         "Windows showing vault files may have stayed open after the lock."),
    "mount point": ("the locked vault folder could not be made read-only",
                    "An app saving into ~/Vault while it is locked could leave a plain copy on disk."),
    "Recent files": ("Recent files could not be cleaned",
                     "Vault file names may be left in Recent files and in search."),
    "thumbnails": ("thumbnails could not be cleaned",
                   "Previews of vault files may be left in ~/.cache/thumbnails."),
    "last-used folders": ("last-used folders could not be cleaned",
                          "A vault folder may be left as a file chooser's last folder."),
    "Text Editor": ("Text Editor's history could not be cleaned",
                    "Vault file names or drafts may be left in Text Editor."),
    "VLC": ("VLC's history could not be switched off or cleaned",
            "VLC may keep vault files in its recent media."),
    "LibreOffice": ("LibreOffice's history could not be switched off or cleaned",
                    "LibreOffice may keep vault documents in its recent list or recovery copies."),
    "Audacity": ("Audacity's history could not be cleaned",
                 "Audacity may keep vault file names in its recent files or logs."),
    "Xournal++": ("Xournal++'s history could not be cleaned",
                  "Xournal++ may keep vault folders, or notes about vault files."),
    "Flatpak documents": ("Flatpak documents could not be cleaned",
                          "The document portal may still list vault file names."),
    "thumbnail switch": ("thumbnails could not be switched",
                         "While the vault is open, previews of its files may be saved."),
    "hiding files": ("vault files could not be hidden",
                     "Files in the vault may show in Files without Ctrl+H."),
    "clipboard": ("the clipboard could not be cleared",
                  "Text copied from a vault file may still paste after the lock."),
    "Brave": ("Brave's history could not be cleaned",
              "Brave may keep vault file names in its history, downloads or address bar."),
    "VS Code": ("VS Code's history could not be cleaned",
                "VS Code may keep vault file names in Open Recent, or backups of vault files."),
}


def warn_part(label):
    trouble, consequence = PARTS.get(label, (f"{label} failed", "Part of the vault is not working."))
    warn(f"part:{label}", f"Vault: {trouble}", f"{consequence} It is retried every 2 minutes.",
         fixed=f"{label} is working again.")


def sd_notify(state):
    """Tell systemd how the guard is doing: READY=1 once it is listening, then
    WATCHDOG=1 regularly. If those stop, systemd restarts it."""
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with contextlib.suppress(OSError), socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(address)
        sock.sendall(state.encode())


def sleep_offset():
    """How long this machine has been suspended since boot. CLOCK_BOOTTIME
    counts suspend and CLOCK_MONOTONIC does not, so their gap grows by exactly
    the time spent asleep."""
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)


# Paths

def in_vault(path):
    """The vault itself or anything in it, by either of its two paths."""
    return bool(path) and any(path == r or path.startswith(r + "/") for r in ROOTS)


def uri_path(uri):
    return Gio.File.new_for_uri(uri).get_path() if uri.startswith("file:") else None


def uri_in_vault(uri):
    return in_vault(uri_path(uri) or "")


def departed(uri):
    """A local file under your home or the temp folder that is not there any
    more. That is what a file moved into the vault leaves: a Recent entry and
    a preview, both under its old name, pointing at nothing. A file you
    deleted, or one on a drive that is not mounted, looks the same, and
    losing its dead entry costs nothing."""
    path = uri_path(uri)
    if not path or in_vault(path):
        return False
    homes = (str(HOME), tempfile.gettempdir())
    return any(in_tree(path, top) for top in homes) and not os.path.lexists(path)


def mentions_vault(text):
    """For settings files, where a vault path can sit anywhere in a line."""
    return bool(text) and bool(VAULT_TEXT.search(text))


def in_tree(path, top):
    return path == top or path.startswith(top + "/")


def mounted():
    """Read the mount table, not the directory: a mount whose gocryptfs died
    cannot be stat'ed, so os.path.ismount calls it unmounted."""
    want = str(MOUNT)
    try:
        with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as f:
            for line in f:
                point = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), line.split(" ", 5)[4])
                if point == want:
                    return True
    except OSError:
        pass
    return False


# Processes

def own_pids():
    for name in os.listdir("/proc"):
        if name.isdigit():
            try:
                if os.stat(f"/proc/{name}").st_uid == UID:
                    yield int(name)
            except OSError:
                pass


def argv_of(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [a.decode("utf-8", "surrogateescape") for a in raw.split(b"\0") if a]


def name_of(pid):
    """The program's own name, with Nix's `.foo-wrapped` read as `foo`."""
    try:
        name = os.path.basename(os.readlink(f"/proc/{pid}/exe").removesuffix(" (deleted)"))
    except OSError:
        argv = argv_of(pid)
        name = os.path.basename(argv[0]) if argv else ""
    if name.startswith(".") and name.endswith("-wrapped"):
        name = name[1:-len("-wrapped")]
    return name


def alive(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def ancestors():
    """This command and the shell that ran it, which must survive a manual close."""
    pids, pid = set(), os.getpid()
    while pid > 1:
        pids.add(pid)
        try:
            pid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return pids


def gocryptfs_pids():
    cipher = str(CIPHER)
    return [p for p in own_pids() if name_of(p) == "gocryptfs" and cipher in argv_of(p)]


def is_open():
    """Mounted and served. A mount whose gocryptfs died counts as locked: it
    can no longer show anything, and lock() is what clears it away."""
    return mounted() and bool(gocryptfs_pids())


def unless_running(label, *names):
    if any(name_of(p) in names for p in own_pids()):
        raise AppRunning(f"{label} is open")


def flatpak_documents():
    """Document portal id to the real path it stands for. A Flatpak app such as
    VLC never sees a vault path, only /run/user/UID/doc/ID/name."""
    try:
        out = subprocess.run(["flatpak", "documents", "--columns=id:f,origin:f"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    docs = {}
    for line in out.splitlines():
        doc_id, _, origin = line.partition("\t")
        if doc_id.strip() and origin.strip():
            docs[doc_id.strip()] = origin.strip()
    return docs


def doc_in_vault(path, docs):
    if not path.startswith(DOCS):
        return False
    parts = path[len(DOCS):].split("/")
    if parts[0] == "by-app" and len(parts) > 2:
        parts = parts[2:]
    return in_vault(docs.get(parts[0], ""))


def touches_vault(pid, docs):
    """Whether pid works in the vault, has a file in it open or mapped, or was
    started on one."""
    base = f"/proc/{pid}"

    def hit(path):
        return in_vault(path) or doc_in_vault(path, docs)

    with contextlib.suppress(OSError):
        if hit(os.readlink(f"{base}/cwd")):
            return True
    with contextlib.suppress(OSError):
        for fd in os.listdir(f"{base}/fd"):
            with contextlib.suppress(OSError):
                if hit(os.readlink(f"{base}/fd/{fd}")):
                    return True
    with contextlib.suppress(OSError):
        with open(f"{base}/maps", encoding="utf-8", errors="surrogateescape") as f:
            for line in f:
                fields = line.rstrip("\n").split(None, 5)
                if len(fields) == 6 and hit(fields[5]):
                    return True
    for arg in argv_of(pid)[1:]:
        value = arg.partition("=")[2] if arg.startswith("-") else arg
        path = uri_path(value) if value.startswith("file:") else value
        if path and hit(path):
            return True
    return False


def vault_users(apps, docs):
    """pid to program name, for everything that has to close before the vault
    locks. `apps` are programs that put a vault file in a recent list: Image
    Viewer and Text Editor keep one process for all their windows and let go
    of a file once it is read, so that list is the only way to know they are
    showing one."""
    skip = ancestors()
    found = {}
    for pid in own_pids():
        if pid in skip:
            continue
        name = name_of(pid)
        if not name or name in KEEP_NAMES or name.startswith(KEEP_PREFIXES):
            continue
        if SELF in argv_of(pid):
            continue
        if name in apps or touches_vault(pid, docs):
            found[pid] = name
    return found


def close_all(procs):
    for pid, name in procs.items():
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGHUP if name in SHELLS else signal.SIGTERM)
    wait_for(lambda: not any(alive(p) for p in procs), 2)
    for pid in procs:
        if alive(pid):
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)


def unmount():
    for pid in gocryptfs_pids():
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGTERM)
    # gocryptfs falls back to a lazy unmount by itself when something still
    # holds the mount. This is for the case where it is already dead.
    if not wait_for(lambda: not mounted(), 3):
        subprocess.run(["fusermount3", "-u", "-z", str(MOUNT)], capture_output=True)
    # The key lives in gocryptfs's memory, so it must not outlive the mount.
    for pid in gocryptfs_pids():
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGKILL)
    return wait_for(lambda: not mounted(), 2)


def harden():
    """A locked mount point is read-only. Without that, an app saving into
    ~/Vault after the lock would write a plain copy straight onto the disk."""
    MOUNT.mkdir(parents=True, exist_ok=True)
    if not mounted():
        os.chmod(MOUNT, 0o500)


# What the desktop would otherwise keep

def dconf(*args):
    return subprocess.run(["dconf", *args], capture_output=True, text=True).stdout.strip()


def set_setting(key, value):
    """Write one dconf key, or reset it when value is empty, then read it
    back: dconf says nothing when a write goes nowhere."""
    if value:
        dconf("write", key, value)
    else:
        dconf("reset", key)
    if dconf("read", key) != value:
        raise RuntimeError("a setting would not change")


def pause_history():
    # Already paused means the file holds the real originals. Overwriting it
    # would save our own "off" as the value to restore.
    if SAVED.exists():
        return
    write_atomic(SAVED, json.dumps({key: dconf("read", key) for key in PAUSED}))
    for key, value in PAUSED.items():
        set_setting(key, value)


def resume_history():
    try:
        saved = json.loads(SAVED.read_text())
    except (OSError, ValueError):
        return
    for key, old in saved.items():
        set_setting(key, old)
    # Only once every one took, so a failure is retried by the next check.
    SAVED.unlink(missing_ok=True)


def program_of(command):
    try:
        words = shlex.split(command.strip().strip("'\""))
    except ValueError:
        words = command.split()
    program = os.path.basename(words[0]) if words else ""
    return None if not program or program in LAUNCHERS else program


def strip_recent(remember=False):
    """Remove vault files from the recent lists, and return how many went.
    With remember, which is for while the vault is open, also note the
    programs that added them, so the lock knows what to close."""
    apps, removed = {}, 0
    for path, owner in RECENT_LISTS:
        bookmarks = GLib.BookmarkFile()
        try:
            bookmarks.load_from_file(str(path))
        except GLib.Error:
            continue
        hits = [uri for uri in bookmarks.get_uris() if uri_in_vault(uri) or departed(uri)]
        for uri in hits:
            if not uri_in_vault(uri):
                bookmarks.remove_item(uri)
                continue
            if owner:
                apps[owner] = "Text Editor"
            with contextlib.suppress(GLib.Error):
                for label in bookmarks.get_applications(uri):
                    with contextlib.suppress(GLib.Error):
                        program = program_of(bookmarks.get_application_info(uri, label)[1])
                        if program:
                            apps[program] = label
            bookmarks.remove_item(uri)
        if hits:
            bookmarks.to_file(str(path))
            removed += len(hits)
    if remember:
        remember_apps(apps)
    return removed


def recall_apps():
    try:
        return json.loads(APPS.read_text())
    except (OSError, ValueError):
        return {}


def remember_apps(apps):
    if apps:
        write_atomic(APPS, json.dumps({**recall_apps(), **apps}))


def thumbnail_uri(path):
    """The Thumb::URI every freedesktop thumbnail records, from its PNG text
    chunks, which come before the image data."""
    try:
        with open(path, "rb") as f:
            if f.read(8) != b"\x89PNG\r\n\x1a\n":
                return None
            while True:
                head = f.read(8)
                if len(head) < 8:
                    return None
                length, kind = struct.unpack(">I4s", head)
                if kind in (b"IDAT", b"IEND") or length > 1 << 20:
                    return None
                data = f.read(length)
                f.read(4)
                if kind in (b"tEXt", b"iTXt"):
                    key, _, rest = data.partition(b"\0")
                    if key == b"Thumb::URI":
                        if kind == b"iTXt":
                            # flag, method, language\0, translated key\0, text
                            rest = rest[2:].split(b"\0", 2)[-1]
                        return rest.decode("utf-8", "replace")
    except OSError:
        return None


def sweep_thumbnails():
    """Previews of vault files, which should never exist because thumbnails
    are off while the vault is open, and previews of files that are gone,
    which is what moving a picture into the vault leaves at its old name."""
    removed = 0
    for png in THUMBNAILS.rglob("*.png"):
        uri = thumbnail_uri(png)
        if uri and (uri_in_vault(uri) or departed(uri)):
            png.unlink(missing_ok=True)
            removed += 1
    return removed


def children(variant):
    return [variant.get_child_value(i) for i in range(variant.n_children())]


def entry(key, value):
    return GLib.Variant.new_dict_entry(GLib.Variant("s", key), GLib.Variant.new_variant(value))


def scrub_text_editor():
    """Take vault files out of Text Editor's saved session and delete their
    drafts. It saves a draft of every changed file every few seconds, and has
    no switch for that which does not also throw away its session. Skipped
    while it runs, because it writes its session back out when it exits."""
    session = TEXT_EDITOR / "session.gvariant"
    if not session.exists():
        return 0
    unless_running("Text Editor", "gnome-text-editor")
    state = GLib.Variant.new_from_bytes(GLib.VariantType("a{sv}"), GLib.Bytes.new(session.read_bytes()), False)
    dropped, drafts = 0, []

    def without_vault(items):
        nonlocal dropped
        kept = []
        for item in children(items):
            uri = item.lookup_value("uri", GLib.VariantType("s"))
            if uri is not None and uri_in_vault(uri.get_string()):
                dropped += 1
                draft = item.lookup_value("draft-id", GLib.VariantType("s"))
                if draft is not None:
                    drafts.append(draft.get_string())
            else:
                kept.append(item)
        return GLib.Variant.new_array(GLib.VariantType("a{sv}"), kept)

    top = []
    for pair in children(state):
        key, value = pair.get_child_value(0).get_string(), pair.get_child_value(1).get_variant()
        if key == "drafts" and value.get_type_string() == "aa{sv}":
            value = without_vault(value)
        elif key == "windows" and value.get_type_string() == "aa{sv}":
            windows = []
            for window in children(value):
                fields = []
                for field in children(window):
                    name, inner = field.get_child_value(0).get_string(), field.get_child_value(1).get_variant()
                    if name == "pages" and inner.get_type_string() == "aa{sv}":
                        inner = without_vault(inner)
                    fields.append(entry(name, inner))
                windows.append(GLib.Variant.new_array(GLib.VariantType("{sv}"), fields))
            value = GLib.Variant.new_array(GLib.VariantType("a{sv}"), windows)
        top.append(entry(key, value))
    if not dropped:
        return 0
    write_atomic(session, GLib.Variant.new_array(GLib.VariantType("{sv}"), top).get_data_as_bytes().get_data())
    for draft in drafts:
        if draft and "/" not in draft:
            (TEXT_EDITOR / "drafts" / draft).unlink(missing_ok=True)
    return dropped


def unexport_documents(docs=None):
    """The document portal remembers every file it ever handed to a Flatpak
    app, by name, until told to forget it."""
    docs = flatpak_documents() if docs is None else docs
    gone = 0
    for doc_id, origin in docs.items():
        if in_vault(origin):
            subprocess.run(["flatpak", "document-unexport", "--doc-id", doc_id], capture_output=True)
            gone += 1
    return gone


def forget_folders():
    """The last folder a file chooser or Text Editor used is kept in dconf.
    One pointing into the vault is reset."""
    reset = 0
    for key in FOLDER_KEYS:
        if mentions_vault(dconf("read", key)):
            dconf("reset", key)
            reset += 1
    return reset


def drop_lines(path):
    """Remove every line of a settings file that names the vault."""
    if not path.exists():
        return 0
    lines = read_text(path).splitlines(keepends=True)
    kept = [line for line in lines if not mentions_vault(line)]
    if len(kept) != len(lines):
        write_atomic(path, "".join(kept))
    return len(lines) - len(kept)


def clean_json(data):
    """Data without anything that names the vault, and how much was taken.
    A list loses whole entries, so a recent list keeps no entry with its path
    cut out; an object loses the keys that name it."""
    removed = 0

    def clean(value):
        nonlocal removed
        if isinstance(value, list):
            kept = [v for v in value if not mentions_vault(json.dumps(v))]
            removed += len(value) - len(kept)
            return [clean(v) for v in kept]
        if isinstance(value, dict):
            kept = {k: v for k, v in value.items()
                    if not mentions_vault(k) and not (isinstance(v, str) and mentions_vault(v))}
            removed += len(value) - len(kept)
            return {k: clean(v) for k, v in kept.items()}
        return value

    return clean(data), removed


def scrub_json(path):
    """Remove every value in a JSON file that names the vault, at any depth."""
    if not path.exists():
        return 0
    data, removed = clean_json(json.loads(read_text(path)))
    if removed:
        write_atomic(path, json.dumps(data, indent=2))
    return removed


def scrub_item_table(path):
    """VS Code's state database: one key per setting, and a value that is
    usually JSON. A value that names the vault is cleaned like a JSON file,
    so Open Recent loses only its vault entries; one that is not JSON goes."""
    if not path.exists():
        return 0
    changed = 0
    con = sqlite3.connect(f"file:{path}?mode=rw", uri=True, timeout=10)
    try:
        for key, value in con.execute("SELECT key, value FROM ItemTable").fetchall():
            text = value.decode(errors="replace") if isinstance(value, bytes) else str(value)
            if not mentions_vault(text) and not mentions_vault(str(key)):
                continue
            try:
                data, _ = clean_json(json.loads(text))
            except ValueError:
                con.execute("DELETE FROM ItemTable WHERE key = ?", (key,))
            else:
                new = json.dumps(data)
                con.execute("UPDATE ItemTable SET value = ? WHERE key = ?",
                            (new.encode() if isinstance(value, bytes) else new, key))
            changed += 1
        con.commit()
        if changed:
            con.execute("VACUUM")
    finally:
        con.close()
    return changed


def delete_mentioning(directory):
    """Delete the files in a folder of logs or notes that name the vault."""
    gone = 0
    if directory.is_dir():
        for file in directory.iterdir():
            if file.is_file() and mentions_vault(read_text(file)):
                file.unlink(missing_ok=True)
                gone += 1
    return gone


def scrub_vlc():
    """VLC's recent media and its resume points: switched off, and the list it
    already has emptied. The open dialog's last folder goes too if it is in
    the vault."""
    if not VLC.exists():
        return 0
    unless_running("VLC", "vlc")
    changed = 0
    rc = VLC / "vlcrc"
    if rc.exists():
        text = new = read_text(rc)
        for key in ("qt-recentplay", "qt-continue"):
            new, found = re.subn(rf"^#?{key}=.*$", f"{key}=0", new, flags=re.M)
            if not found:
                new, found = re.subn(r"^\[qt\].*$", lambda m, k=key: f"{m.group(0)}\n{k}=0", new, count=1, flags=re.M)
            if not found:
                new += f"\n[qt]\n{key}=0\n"
        if new != text:
            write_atomic(rc, new)
            changed += 1
    conf = VLC / "vlc-qt-interface.conf"
    if conf.exists():
        lines = read_text(conf).splitlines(keepends=True)
        kept, section = [], None
        for line in lines:
            if line.startswith("["):
                section = line.strip()
            if section == "[RecentsMRL]" or mentions_vault(line):
                continue
            kept.append(line)
        if kept != lines:
            write_atomic(conf, "".join(kept))
            changed += len(lines) - len(kept)
    return changed


def scrub_libreoffice():
    """LibreOffice's recent documents, thumbnails included: switched off, and
    the list emptied. Its crash-recovery copies of vault files are deleted:
    it keeps a plain copy of a document open long enough, and a lock closing
    it is exactly the kind of exit that leaves one behind. Anything else in
    its settings that names the vault, such as a dialog's last folder, goes.

    Edited a line at a time, never parsed and written back whole: LibreOffice
    writes one setting per line, and an XML library rewriting the file drops
    the xs namespace that its oor:type="xs:string" values depend on."""
    xcu = LIBREOFFICE / "registrymodifications.xcu"
    # Its temp folders hold copies of open documents. It removes them when it
    # quits, but not when the lock closes it, and they are useless once it
    # is gone.
    scratch = [d for d in Path(tempfile.gettempdir()).glob("lu*.tmp")
               if d.is_dir() and not d.is_symlink() and d.stat().st_uid == UID]
    if not xcu.exists() and not scratch:
        return 0
    unless_running("LibreOffice", "soffice.bin")
    for folder in scratch:
        shutil.rmtree(folder, ignore_errors=True)
    if not xcu.exists():
        return len(scratch)
    # A file that is not a whole LibreOffice registry is left alone, and the
    # error says so.
    if ET.parse(xcu).getroot().tag != f"{{{OOR}}}items":
        raise ValueError("not a LibreOffice registry")
    lines = read_text(xcu).splitlines(keepends=True)
    kept, changed, size_set = [], len(scratch), False
    for line in lines:
        item = libreoffice_item(line)
        if item is None:
            kept.append(line)
            continue
        path = item.get(f"{{{OOR}}}path", "")
        if "HistoryInfo['PickList']" in path:
            changed += 1
            continue
        if path == "/org.openoffice.Office.Common/History" and 'oor:name="PickListSize"' in line:
            size_set = True
            new = re.sub(r'(oor:name="PickListSize"[^>]*><value>)[^<]*(</value>)', r"\g<1>0\g<2>", line)
            changed += new != line
            kept.append(new)
            continue
        if mentions_vault(line):
            if path.startswith("/org.openoffice.Office.Recovery/RecoveryList"):
                for temp in item.iterfind(f".//prop[@{{{OOR}}}name='TempURL']/value"):
                    copy = uri_path(temp.text or "")
                    if copy and in_tree(copy, str(LIBREOFFICE / "backup")):
                        Path(copy).unlink(missing_ok=True)
            changed += 1
            continue
        kept.append(line)
    if not size_set:
        setting = ('<item oor:path="/org.openoffice.Office.Common/History"><prop oor:name="PickListSize" '
                   'oor:op="fuse"><value>0</value></prop></item>\n')
        end = next((i for i in range(len(kept) - 1, -1, -1) if "</oor:items>" in kept[i]), len(kept))
        kept.insert(end, setting)
        changed += 1
    if changed > len(scratch):
        write_atomic(xcu, "".join(kept))
    return changed


def libreoffice_item(line):
    """One <item> line of registrymodifications.xcu, parsed on its own, or None."""
    if not line.lstrip().startswith("<item "):
        return None
    try:
        wrapper = ET.fromstring(f'<r xmlns:oor="{OOR}" xmlns:xs="{XS}" xmlns:xsi="{XSI}">{line.strip()}</r>')
    except ET.ParseError:
        return None
    return wrapper[0] if len(wrapper) else None


def clear_clipboard():
    """GNOME keeps what was copied even after the app that copied it closes,
    so text copied out of a vault file would still paste after the lock.
    Both selections: Ctrl+C's and the one a middle click pastes. Through
    xclip, because the Wayland tools flash a window to do it."""
    if not os.environ.get("DISPLAY"):
        return 0
    for selection in ("clipboard", "primary"):
        # xclip stays behind to serve the empty selection, so no pipes for it to hold.
        subprocess.run(["xclip", "-selection", selection, "-i", "/dev/null"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    return 2


def scrub_database(path):
    """Delete every row of an SQLite database whose text names the vault, in
    any table, then VACUUM: SQLite leaves deleted rows readable in the file
    until it is rewritten."""
    if not path.exists():
        return 0
    gone = 0
    con = sqlite3.connect(f"file:{path}?mode=rw", uri=True, timeout=10)
    try:
        tables = [row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            columns = [row[1] for row in con.execute(f"PRAGMA table_info({quoted})")]
            for column in columns:
                col = '"' + column.replace('"', '""') + '"'
                for root in ROOTS:
                    literal = root.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                    for pattern in (f"%{literal}/%", f"%{literal}"):
                        gone += con.execute(f"DELETE FROM {quoted} WHERE CAST({col} AS TEXT) LIKE ? ESCAPE '\\'",
                                            (pattern,)).rowcount
        con.commit()
        if gone:
            con.execute("VACUUM")
    finally:
        con.close()
    return gone


def scrub_brave():
    """Brave's history, downloads, address-bar suggestions and last folders,
    for any vault file opened or saved in it, in every profile. Only while it
    is closed: it keeps these files open and would write them back."""
    profiles = [p for p in BRAVE.iterdir() if (p / "Preferences").exists()] if BRAVE.is_dir() else []
    if not profiles:
        return 0
    unless_running("Brave", "brave")
    changed = 0
    for profile in profiles:
        for name in BRAVE_DATABASES:
            changed += scrub_database(profile / name)
        changed += scrub_json(profile / "Preferences")
    return changed


def scrub_vscode():
    """VS Code's Open Recent list and window state, the saved state of any
    workspace in the vault, unsaved changes it backed up from vault files, and
    old file versions from before localHistory.exclude. Only while it is
    closed, for the same reason as Brave."""
    if not VSCODE.is_dir():
        return 0
    unless_running("VS Code", "code")
    changed = scrub_item_table(VSCODE / "User/globalStorage/state.vscdb")
    changed += scrub_json(VSCODE / "User/globalStorage/storage.json")
    changed += scrub_json(VSCODE / "Backups/workspaces.json")
    for marker in ("User/workspaceStorage/*/workspace.json", "User/History/*/entries.json"):
        for found in VSCODE.glob(marker):
            if mentions_vault(read_text(found)):
                shutil.rmtree(found.parent, ignore_errors=True)
                changed += 1
    backups = VSCODE / "Backups"
    if backups.is_dir():
        for file in backups.rglob("*"):
            # A backup starts with the path of the file it was taken from.
            if file.is_file() and file.name != "workspaces.json":
                with open(file, "rb") as f:
                    head = f.readline(4096).decode(errors="replace")
                if mentions_vault(head):
                    file.unlink(missing_ok=True)
                    changed += 1
    return changed


def scrub_audacity():
    """Audacity's recent files, open projects, saved session and logs. It has
    no switch for any of them, and its logs name every file it opens."""
    if not (AUDACITY.exists() or AUDACITY_INI.exists()):
        return 0
    unless_running("Audacity", "audacity")
    return (scrub_json(AUDACITY / "recent_files.json") + scrub_json(AUDACITY / "session/session.json")
            + drop_lines(AUDACITY_INI) + delete_mentioning(AUDACITY / "logs"))


def scrub_xournalpp():
    """Xournal++'s last-used folders, and the notes it files by document path
    (last page, zoom). Its recent list is GTK's, which strip_recent covers."""
    if not (XOURNALPP.exists() or any(d.is_dir() for d in XOURNALPP_NOTES)):
        return 0
    unless_running("Xournal++", "xournalpp")
    changed = sum(delete_mentioning(d) for d in XOURNALPP_NOTES)
    if XOURNALPP.exists():
        text = read_text(XOURNALPP)
        new = re.sub(r'(<property name="last\w*Path" value=")([^"]*)(")',
                     lambda m: m.group(1) + ("" if mentions_vault(m.group(2)) else m.group(2)) + m.group(3), text)
        if new != text:
            write_atomic(XOURNALPP, new)
            changed += 1
    return changed


def sweep(report, vault_open, docs=None):
    """Clear every trace this can reach. Each part runs on its own, and one
    whose app is open is left for the next check, every two minutes."""
    attempt(report, "Recent files", strip_recent, vault_open)
    attempt(report, "thumbnails", sweep_thumbnails)
    attempt(report, "last-used folders", forget_folders)
    attempt(report, "Text Editor", scrub_text_editor)
    attempt(report, "VLC", scrub_vlc)
    attempt(report, "LibreOffice", scrub_libreoffice)
    attempt(report, "Audacity", scrub_audacity)
    attempt(report, "Xournal++", scrub_xournalpp)
    attempt(report, "Brave", scrub_brave)
    attempt(report, "VS Code", scrub_vscode)
    # Not while open: a Flatpak app may be reading one of them right now.
    if not vault_open:
        attempt(report, "Flatpak documents", unexport_documents, docs)


def hide_in(directory, names=None):
    """List every entry in the directory's .hidden, which GIO reads, so Files
    and the file chooser show the vault as empty until you press Ctrl+H."""
    try:
        names = os.listdir(directory) if names is None else names
    except OSError:
        return
    names = sorted(n for n in names if not n.startswith(".") and "\n" not in n)
    want = "".join(f"{n}\n" for n in names)
    hidden = os.path.join(directory, ".hidden")
    try:
        with open(hidden, encoding="utf-8", errors="surrogateescape") as f:
            have = f.read()
    except FileNotFoundError:
        have = None
    except OSError:
        return
    if have == want or (have is None and not names):
        return
    with contextlib.suppress(OSError):
        tmp = os.path.join(directory, ".hidden.tmp")
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(want)
        os.replace(tmp, hidden)


def hide_everything():
    for directory, dirs, files in os.walk(MOUNT):
        hide_in(directory, dirs + files)
    # GNOME's search indexer skips any folder holding this file. It does not
    # index /run/user anyway; this holds even if it is pointed here later.
    marker = MOUNT / ".trackerignore"
    if mounted() and not marker.exists():
        marker.touch()


# Open and lock

@contextlib.contextmanager
def held(wait=True):
    """One vault command at a time. Raises BlockingIOError when wait is False
    and another holds it."""
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(STATE / "lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        yield


def lock(wait=True):
    """Close everything using the vault, lock it, and clear what it left
    behind. Returns (programs closed, report), or None when another vault
    command holds the lock. Safe on a locked vault: it then only clears, which
    is also how a crash, a reboot or a dead guard gets cleaned up.

    Every part runs on its own. Only the unmount may not fail quietly: if
    finding or closing programs breaks, the vault still locks."""
    try:
        with held(wait), shielded():
            report, closed, docs = [], [], None
            if mounted() or gocryptfs_pids():
                attempt(report, "reading Recent files", strip_recent, True)
                docs = attempt(report, "reading Flatpak documents", flatpak_documents)
                users = attempt(report, "finding programs", vault_users, recall_apps(), docs or {}) or {}
                attempt(report, "closing programs", close_all, users)
                closed = sorted(set(users.values()))
                if not attempt(report, "unmounting", unmount):
                    raise RuntimeError("it is still mounted")
                attempt(report, "clipboard", clear_clipboard)
            attempt(report, "mount point", harden)
            sweep(report, vault_open=False, docs=docs)
            attempt(report, "thumbnail switch", resume_history)
            for state in (APPS, OPENED):
                state.unlink(missing_ok=True)
            return closed, report
    except BlockingIOError:
        return None


# The check

def ensure_setup():
    """~/Vault links to the mount point and ~/.hidden lists it. make home sets
    both; this puts them back if something undid them."""
    fixed = 0
    if LINK.is_symlink():
        if os.readlink(LINK) != str(MOUNT):
            LINK.unlink()
            LINK.symlink_to(MOUNT)
            fixed += 1
    elif LINK.exists():
        raise FileExistsError("~/Vault is not the vault's link")
    else:
        LINK.symlink_to(MOUNT)
        fixed += 1
    hidden = LINK.parent / ".hidden"
    names = read_text(hidden).splitlines() if hidden.exists() else []
    if LINK.name not in names:
        text = read_text(hidden) if hidden.exists() else ""
        write_atomic(hidden, text + ("" if not text or text.endswith("\n") else "\n") + LINK.name + "\n")
        fixed += 1
    # Not over a mount: a dead one cannot even be looked at, and lock() is
    # what clears that.
    if not mounted():
        MOUNT.mkdir(parents=True, exist_ok=True)
    return fixed


def guard_running():
    # Only stopped or failed is dead. One starting or stopping is in hand
    # already, and restarting it then would only start it over; the next
    # check sees how it ended up.
    state = subprocess.run(["systemctl", "--user", "is-active", GUARD], capture_output=True, text=True).stdout.strip()
    return state not in ("inactive", "failed", "")


def ensure_guard():
    if guard_running():
        return 0
    if subprocess.run(["systemctl", "--user", "cat", GUARD], capture_output=True).returncode != 0:
        raise FileNotFoundError("there is no vault-guard unit to start")
    subprocess.run(["systemctl", "--user", "restart", GUARD], capture_output=True)
    if wait_for(guard_running, 5):
        return 1
    raise ChildProcessError("vault-guard will not start")


def ensure_paused():
    """Thumbnails stay off for as long as the vault is open, whoever flipped
    them back."""
    if not SAVED.exists():
        pause_history()
        return 1
    fixed = 0
    for key, value in PAUSED.items():
        if dconf("read", key) != value:
            set_setting(key, value)
            fixed += 1
    return fixed


def session_call(name, path, interface, method, args=None):
    """One GNOME session call, or None when there is no answer (no desktop)."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        # NO_AUTO_START: ask whoever is there, never start a service just to ask.
        return bus.call_sync(name, path, interface, method, args, None,
                             Gio.DBusCallFlags.NO_AUTO_START, 2000, None).unpack()[0]
    except GLib.Error:
        return None


def missed_lock():
    """Why the vault should already be locked, if it should: the guard may
    have missed the signal, or not be running at all."""
    if session_call("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver", "GetActive"):
        return "the screen is locked"
    idle = session_call("org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                        "org.gnome.Mutter.IdleMonitor", "GetIdletime")
    # 8 is GNOME's idle inhibit: a video playing, which also keeps the screen on.
    inhibited = session_call("org.gnome.SessionManager", "/org/gnome/SessionManager",
                             "org.gnome.SessionManager", "IsInhibited", GLib.Variant("(u)", (8,)))
    if idle is not None and idle >= IDLE_SECONDS * 1000 and not inhibited:
        return f"you were idle for {IDLE_SECONDS // 60} minutes"
    try:
        opened = json.loads(OPENED.read_text())["sleep"]
    except (OSError, ValueError, KeyError):
        opened = None
    if opened is not None and sleep_offset() - opened > 5:
        return "the laptop slept while it was open"
    return None


def check(quiet):
    """Test every part and repair what can be repaired. Run by vault-check.timer
    every two minutes, separately from the guard, so a guard that died or
    missed a signal is covered: this locks the vault itself when the screen
    is locked, you have been idle long enough, or the laptop slept while it
    was open."""
    previous = load_json(CHECKED)
    report, reason, lock_error = [], None, None
    attempt(report, "~/Vault link and ~/.hidden", ensure_setup)
    restarted = attempt(report, "vault-guard", ensure_guard)
    if is_open():
        reason = attempt(report, "missed locks", missed_lock)
    if reason or not is_open():
        try:
            result = lock(wait=False)
        except RuntimeError as error:
            lock_error, result = str(error), ([], [])
        if result is None:
            return 0  # another vault command is busy; the next run picks this up
        report += result[1]
    else:
        try:
            with held(wait=False):
                attempt(report, "thumbnail switch", ensure_paused)
                attempt(report, "hiding files", hide_everything)
                sweep(report, vault_open=True)
        except BlockingIOError:
            return 0
    review(report, restarted, reason, lock_error, previous)
    # A quiet run that got this far proves the timer's check runs again.
    if quiet:
        clear_alarm(CHECK)
    if guard_running():
        clear_alarm(GUARD)
    cleaned = [(label, n) for label, status, n in report if status == "ok" and counted(n)]
    if quiet:
        if cleaned:
            log("cleared: " + ", ".join(f"{label} ({n})" for label, n in cleaned))
        return 0
    print("The vault is open." if is_open() else "The vault is locked.")
    if reason:
        print(f"It locked now because {reason}, which the guard missed.")
    for label, status, detail in report:
        if status == "failed":
            print(f"  FAILED   {label} ({detail})")
        elif status == "later":
            print(f"  later    {label}: {detail}, so it is checked again once it closes")
        elif counted(detail):
            print(f"  fixed    {label} ({detail})")
        else:
            print(f"  ok       {label}")
    incidents = take_incidents()
    conditions = active_warnings()
    for unit, message in alarms().items():
        print(f"\n⚠ {message.removeprefix('Vault: ')}: systemd could not run it. See "
              f"`journalctl --user -u {unit}`. This clears once the 2-minute check runs again.")
    if conditions:
        print("\nStill wrong:")
        for w in sorted(conditions.values(), key=lambda w: w["since"]):
            print(f"  ⚠ {w['title'].removeprefix('Vault: ')}. {w['body']}")
    if incidents:
        print("\nWhat happened since you last looked (cleared now that you have seen it):")
        for w in sorted(incidents.values(), key=lambda w: w["since"]):
            when = time.strftime("%a %H:%M", time.localtime(w["since"]))
            print(f"  ⚠ {when}  {w['title'].removeprefix('Vault: ')}. {w['body']}")
    return 1 if conditions or alarms() or problems(report) else 0


def load_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def journal_mentions(since):
    """How many log lines since then name a file inside the vault. Only
    counted: the lines are never printed, logged or kept."""
    pattern = "(?:%s)/[^\\s]" % "|".join(re.escape(r) for r in ROOTS)
    try:
        out = subprocess.run(["journalctl", "--no-pager", "-q", "-o", "cat", f"--since=@{int(since)}",
                              "--case-sensitive=yes", "-g", pattern],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0
    return sum(1 for line in out.splitlines() if line.strip())


def guard_restarts():
    out = subprocess.run(["systemctl", "--user", "show", GUARD, "-p", "NRestarts", "--value"],
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else 0


def guard_health():
    """What the guard last said about itself, if it is alive to have said it."""
    health = load_json(HEALTH)
    return health if health and alive(health.get("pid", 0)) else None


def review(report, restarted, reason, lock_error, previous):
    """Turn what a check found into warnings, and clear the ones it found
    working again."""
    for label, status, _ in report:
        if label == "vault-guard":
            continue
        if status == "failed":
            warn_part(label)
        elif status == "ok":
            resolve(f"part:{label}")

    guard = next((status for label, status, _ in report if label == "vault-guard"), None)
    if guard == "failed":
        warn("guard-down", "Vault: auto-lock is not working",
             "vault-guard is not running and would not start, so the vault does not lock the moment "
             "the screen locks or the laptop sleeps. This check still locks it, within 2 minutes.",
             fixed="Auto-lock is working again: vault-guard is running.")
    elif guard == "ok":
        resolve("guard-down")
        if restarted:
            warn("guard-stopped", "Vault: the guard had stopped",
                 "vault-guard was not running, so this check started it again. Until then, only this "
                 "check could lock the vault.", incident=True)

    restarts, base = guard_restarts(), previous.get("guard_restarts")
    if base is not None and restarts > base:
        times = restarts - base
        warn("guard-crashed", "Vault: the guard crashed",
             f"vault-guard stopped {times} time{'s' if times > 1 else ''} and restarted itself. "
             "See `journalctl --user -u vault-guard` for why.", incident=True)

    health = guard_health()
    if health is not None:
        if health.get("idle_watch") is False:
            warn("guard-idle", "Vault: the idle lock is not working",
                 "GNOME's idle monitor did not answer the guard, so going idle does not lock the vault "
                 "right away. This check still locks it, within 2 minutes of the idle time passing.",
                 fixed="The idle lock is working again.")
        else:
            resolve("guard-idle")
        if is_open() and health.get("inhibitor") is False:
            warn("guard-sleep", "Vault: the vault may not lock before sleep",
                 "The system would not let the guard hold off sleep, so the vault may only lock once "
                 "the laptop wakes.", fixed="The vault locks before sleep again.")
        else:
            resolve("guard-sleep")
        if time.time() - health.get("beat", 0) > 120:
            warn("guard-hung", "Vault: the guard is not responding",
                 "vault-guard has not checked in for over 2 minutes, and systemd should have restarted it.",
                 fixed="vault-guard is responding again.")
        else:
            resolve("guard-hung")

    since = previous.get("time") or time.time() - 86400
    named = journal_mentions(since)
    if named:
        warn("journal", "Vault: vault file names reached the system log",
             f"{named} log line{'s' if named > 1 else ''} since "
             f"{time.strftime('%a %H:%M', time.localtime(since))} name files in the vault. An app printed "
             "them; the vault cannot take single lines out of the log. To wipe the whole log: "
             "`sudo journalctl --rotate && sudo journalctl --vacuum-time=1s`", incident=True)

    if reason:
        warn("missed-lock", "Vault: the guard missed a lock",
             f"The vault was still open although {reason}, so this check locked it.", incident=True)
    if lock_error:
        warn("lock-failed", "Vault: the vault could not lock",
             f"It is still open ({lock_error}). Close the programs using it, then run `vault close`.",
             fixed="The vault is locked now.")
    elif not is_open():
        resolve("lock-failed")

    # A long gap since the last check means a login, a wake or a reboot in
    # between, and a warning raised before it may never have been seen.
    if previous.get("time") and time.time() - previous["time"] > 600:
        remind_all()
    write_atomic(CHECKED, json.dumps({"time": time.time(), "guard_restarts": restarts}))


# Commands

MIN_PASSWORD = 12

# What gocryptfs's exit codes mean, for the ones a person can act on.
GOCRYPTFS_ERRORS = {
    6: "~/.vault could not be used",
    8: "~/.vault/gocryptfs.conf could not be read; the master key can still open it",
    9: "no password was given",
    10: "the folder it opens into could not be used",
    17: "~/.vault/gocryptfs.conf could not be opened",
}


class Cancelled(Exception):
    """Stopped by you (Ctrl+C, Ctrl+D or a closed terminal) where stopping is
    safe. The message, if any, says what was left as it was."""


def ask(prompt):
    """A password, read with the terminal's echo off and put back after,
    however it ends. Ctrl+D cancels the same as Ctrl+C."""
    try:
        return getpass.getpass(prompt)
    except EOFError:
        print()
        raise Cancelled() from None


@contextlib.contextmanager
def shielded():
    """Hold off Ctrl+C, a closed terminal and SIGTERM until the block is done:
    a lock stopped halfway would leave programs closed and the vault open.
    Ignored rather than caught, because an ignored signal stays ignored in
    the programs started meanwhile, so none of them is killed halfway either."""
    signals = (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
    before = {s: signal.getsignal(s) for s in signals}
    for s in signals:
        signal.signal(s, signal.SIG_IGN)
    try:
        yield
    finally:
        for s, handler in before.items():
            signal.signal(s, handler if handler is not None else signal.SIG_DFL)


def gocryptfs(args, password):
    """Run gocryptfs with the password on its stdin: never on its command line,
    where any program could read it, nor in its environment. Output goes to a
    file, not a pipe, because the mount leaves a daemon behind that would hold
    a pipe open. Returns the exit code and the last thing it printed."""
    with tempfile.TemporaryFile() as out:
        code = subprocess.run(args, input=password + "\n", text=True, stdout=out, stderr=out).returncode
        out.seek(0)
        lines = [line for line in out.read().decode(errors="replace").splitlines() if line.strip()]
    return code, re.sub(r"\x1b\[[0-9;]*m", "", lines[-1]) if lines else ""


def master_key(password):
    """The vault's master key, written the way gocryptfs writes it, or None
    for a wrong password."""
    result = subprocess.run(["gocryptfs-xray", "-dumpmasterkey", str(CIPHER / "gocryptfs.conf")],
                            input=password + "\n", text=True, capture_output=True)
    found = re.findall(r"\b[0-9a-f]{64}\b", result.stdout)
    if result.returncode != 0 or not found:
        return None
    groups = [found[-1][i:i + 8] for i in range(0, 64, 8)]
    return "-".join(groups[:4]) + "-\n    " + "-".join(groups[4:])


def show_master_key(key):
    print("\nThis is your vault's master key. It opens the vault even if you forget the password:\n")
    print(f"    {key}\n")
    print("Save it in your password manager now. If you lose both, nothing in the vault can be recovered.")
    try:
        input("Press Enter once it is saved, and it is wiped from this screen. ")
    except EOFError:
        pass
    finally:
        # The screen and the scrollback both, so the key is not left above.
        sys.stdout.write("\033[H\033[2J\033[3J")
        sys.stdout.flush()


def create_vault():
    """Make a new, empty vault and return its password, so that opening it
    right after does not ask a third time."""
    if CIPHER.exists() and any(CIPHER.iterdir()):
        die("~/.vault has files in it but is not a vault. Move them out first")
    print("Creating your vault.")
    print(f"Choose a password of at least {MIN_PASSWORD} characters. Four or five random words work well.")
    while True:
        password = ask("New vault password: ")
        if len(password) < MIN_PASSWORD:
            print(f"That is {len(password)} characters. Use at least {MIN_PASSWORD}.")
            continue
        if ask("Type it again: ") != password:
            print("Those did not match. Try again.")
            continue
        break
    try:
        CIPHER.mkdir(mode=0o700, parents=True, exist_ok=True)
        # -scryptn 18: four times gocryptfs's default work for each password
        # guess, which costs about half a second at each unlock.
        code, said = gocryptfs(["gocryptfs", "-init", "-q", "-scryptn", "18", "-passfile", "/dev/stdin",
                                str(CIPHER)], password)
        if code != 0:
            die(f"the vault was not created: {said}")
        key = master_key(password)
        if key is None:
            print("The master key could not be read. Run `vault key` to see it.")
        else:
            show_master_key(key)
    except BaseException:
        # A half-made vault is only in the way. A finished one stays, even if
        # you stopped while its key was on screen: `vault key` shows it again.
        if not (CIPHER / "gocryptfs.conf").exists():
            shutil.rmtree(CIPHER, ignore_errors=True)
        raise
    return password


def unlock():
    if mounted():
        # gocryptfs died and left its mount behind.
        subprocess.run(["fusermount3", "-u", "-z", str(MOUNT)], capture_output=True)
    password = None if (CIPHER / "gocryptfs.conf").exists() else create_vault()
    try:
        # Before the mount, so no vault file is ever visible with thumbnails on.
        try:
            pause_history()
        except RuntimeError:
            warn_part("thumbnail switch")
            print("⚠ Thumbnails could not be switched off, so previews of vault files may be saved.")
        MOUNT.mkdir(parents=True, exist_ok=True)
        if any(MOUNT.iterdir()):
            die(f"{MOUNT} should be empty while the vault is locked. Move what is in it out first")
        # fusermount3 refuses a mount point it cannot write to.
        os.chmod(MOUNT, 0o700)
        for _ in range(3):
            if password is None:
                password = ask("Vault password: ")
            if not password:
                print("No password typed.")
                password = None
                continue
            # A scope of its own, so closing this terminal leaves the vault open.
            code, said = gocryptfs(["systemd-run", "--user", "--scope", "--quiet", "--collect",
                                    "--description=Vault (gocryptfs)", "--", "gocryptfs", "-q",
                                    "-passfile", "/dev/stdin", str(CIPHER), str(MOUNT)], password)
            password = None
            if code == 0 and mounted():
                break
            if code == 12:
                print("Wrong password.")
                continue
            die(f"the vault did not open: {GOCRYPTFS_ERRORS.get(code, said or f'gocryptfs stopped with code {code}')}")
        else:
            die("wrong password three times. The vault is still locked")
        # So `vault check` can tell later that the laptop slept while it
        # was open, even if the guard was not running to see it.
        write_atomic(OPENED, json.dumps({"sleep": sleep_offset()}))
        hide_everything()
    finally:
        # However it ended short of open: cancelled, wrong password, an
        # error. The locked folder goes back to read-only, thumbnails back on.
        if not mounted():
            with contextlib.suppress(Exception):
                harden()
            try:
                resume_history()
            except Exception:
                warn_part("thumbnail switch")


def open_vault(show):
    if not sys.stdin.isatty():
        die("vault open asks for your password, so run it in a terminal")
    try:
        with held(wait=False):
            if is_open():
                print("The vault is already open at ~/Vault.")
            else:
                unlock()
    except BlockingIOError:
        die("another vault command is running. Try again in a moment")
    subprocess.run(["systemctl", "--user", "kill", "--signal=SIGUSR1", GUARD], capture_output=True)
    print("The vault is open at ~/Vault. Its files are hidden: press Ctrl+H in Files to see them.")
    if not guard_running():
        log("vault-guard is not running, so the vault does not lock the moment the screen does. "
            "The 2-minute check still locks it")
    if active_warnings() or alarms():
        print("⚠ The vault has warnings. Run `vault check` to see them.")
    if show and (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
        try:
            Gio.AppInfo.launch_default_for_uri(LINK.as_uri(), None)
        except GLib.Error:
            subprocess.run(["xdg-open", str(LINK)], capture_output=True)


def key_command():
    """Show the master key again, for when it was not saved the first time."""
    if not sys.stdin.isatty():
        die("vault key asks for your password, so run it in a terminal")
    if not (CIPHER / "gocryptfs.conf").exists():
        die("there is no vault yet. Run `vault open` to create one")
    for _ in range(3):
        key = master_key(ask("Vault password: "))
        if key is not None:
            show_master_key(key)
            return
        print("Wrong password.")
    die("wrong password three times")


def close_command(session_ending):
    if session_ending:
        # ExecStop of the guard. A restart (make home) runs it too, and must
        # not lock a vault you are using. Only a session going down does.
        state = subprocess.run(["systemctl", "--user", "is-active", "graphical-session.target"],
                               capture_output=True, text=True).stdout.strip()
        if state == "active":
            return
    was_open = mounted()
    if was_open and not session_ending:
        print("Locking the vault.")
    try:
        result = lock(wait=False)
        if result is None:
            print("Waiting for another vault command to finish.")
            result = lock()
        closed, report = result
    except RuntimeError as error:
        # At logout this notification may not be seen; the warning stays and
        # is shown again after the next login.
        warn("lock-failed", "Vault: the vault could not lock",
             f"It is still open ({error}). Close the programs using it, then run `vault close`.",
             fixed="The vault is locked now.")
        die(f"could not lock the vault: {error}")
    resolve("lock-failed")
    if not was_open:
        print("The vault is already locked." if (CIPHER / "gocryptfs.conf").exists() else "There is no vault yet.")
    else:
        print("Locked." + (f" Closed: {', '.join(closed)}." if closed else ""))
    if problems(report):
        print("Some clean-up failed: " + ", ".join(problems(report)) + ". `vault check` retries it.")
    if in_vault(os.environ.get("PWD", "")):
        print("This shell was inside the vault. Run `cd` to leave it.")


def move_in(source, dest):
    """Copy into the vault, then delete the original. Stopped during the copy,
    the partial copy goes and the original stays; once copied, deleting the
    original is not stopped halfway."""
    is_dir = source.is_dir() and not source.is_symlink()
    try:
        if is_dir:
            shutil.copytree(source, dest, symlinks=True)
        else:
            shutil.copy2(source, dest, follow_symlinks=False)
    except BaseException:
        if dest.is_dir() and not dest.is_symlink():
            shutil.rmtree(dest, ignore_errors=True)
        else:
            dest.unlink(missing_ok=True)
        raise
    with shielded():
        if is_dir:
            shutil.rmtree(source)
        else:
            source.unlink()


def add_command(paths):
    """Move files and folders into the vault, and clear what they leave
    behind where they were: their previews and their Recent entries. Unlike
    a drag in Files, which copies across drives, nothing stays outside."""
    if not paths:
        die("usage: vault add <file or folder>...")
    if not is_open():
        die("the vault is locked. Run `vault open` first")
    moved = 0
    try:
        for raw in paths:
            source = Path(os.path.abspath(Path(raw).expanduser()))
            real = os.path.realpath(source)
            name = source.name
            if not source.exists() and not source.is_symlink():
                print(f"Skipped {raw}: it does not exist.")
            elif in_vault(str(source)) or in_vault(real):
                print(f"Skipped {raw}: it is already in the vault.")
            elif in_tree(str(CIPHER), real) or in_tree(str(LINK), str(source)) or in_tree(str(CIPHER), str(source)):
                print(f"Skipped {raw}: it holds the vault itself.")
            elif (MOUNT / name).exists() or (MOUNT / name).is_symlink():
                print(f"Skipped {raw}: the vault already has something called {name}.")
            else:
                move_in(source, MOUNT / name)
                moved += 1
                print(f"Moved {name} into the vault." + (" It is a link; what it points to stays where it is."
                                                          if source.is_symlink() else ""))
    except KeyboardInterrupt:
        raise Cancelled(f"Cancelled. {moved} of {len(paths)} moved in; the rest are where they were.") from None
    finally:
        hide_in(str(MOUNT))
        if moved:
            # Their previews and Recent entries now point at nothing.
            report = []
            attempt(report, "Recent files", strip_recent, True)
            attempt(report, "thumbnails", sweep_thumbnails)
            for label in problems(report):
                warn_part(label)


def status():
    if not (CIPHER / "gocryptfs.conf").exists():
        print("There is no vault yet. Run `vault open` to create one.")
    elif is_open():
        users = vault_users(recall_apps(), flatpak_documents())
        print("Open at ~/Vault.")
        if users:
            print("In use by: " + ", ".join(sorted(set(users.values()))) + ".")
    elif mounted():
        print("Half open: its gocryptfs stopped. Run `vault close` to clear it.")
    else:
        print("Locked.")
    if guard_running():
        print(f"It locks itself after {IDLE_SECONDS // 60} minutes idle, when the screen locks, "
              "before sleep and at logout.")
    else:
        print("Auto-lock is off: vault-guard is not running. See `systemctl --user status vault-guard`.")
    for w in sorted(active_warnings().values(), key=lambda w: w["since"]):
        print(f"⚠ {w['title']}")
    for message in alarms().values():
        print(f"⚠ {message}")
    if active_warnings() or alarms():
        print("Run `vault check` for details.")


# The guard

class Guard:
    """Locks the vault when you go idle, the screen locks, the laptop sleeps or
    the session ends (that last one through the unit's ExecStop). While the
    vault is open it also keeps every file in it hidden and the recent lists
    clear of it."""

    MOVES = {Gio.FileMonitorEvent.CREATED, Gio.FileMonitorEvent.MOVED_IN, Gio.FileMonitorEvent.RENAMED,
             Gio.FileMonitorEvent.DELETED, Gio.FileMonitorEvent.MOVED_OUT}

    def __init__(self):
        self.session = Gio.bus_get_sync(Gio.BusType.SESSION)
        self.system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
        self.armed = False
        self.inhibitor = None
        self.idle_id = None
        self.dirs = {}
        self.recent = []
        self.pending = set()
        self.flush_id = None
        self.strip_id = None
        self.ticks = 0

    def run(self):
        # Clear what a crash or a reboot left. Never wait for the lock here: a
        # `vault open` at its password prompt holds it, and the timer's check
        # picks up anything skipped.
        if not mounted():
            with contextlib.suppress(Exception):
                lock(wait=False)
        self.session.signal_subscribe(None, "org.gnome.ScreenSaver", "ActiveChanged", "/org/gnome/ScreenSaver",
                                      None, Gio.DBusSignalFlags.NONE, self.on_screensaver)
        self.session.signal_subscribe(None, "org.gnome.Mutter.IdleMonitor", "WatchFired",
                                      "/org/gnome/Mutter/IdleMonitor/Core", None, Gio.DBusSignalFlags.NONE,
                                      self.on_idle)
        self.system.signal_subscribe(None, "org.freedesktop.login1.Manager",
                                     "PrepareForSleep", "/org/freedesktop/login1", None,
                                     Gio.DBusSignalFlags.NONE, self.on_sleep)
        self.add_idle_watch()
        self.report_health()
        # Polled, and poked with SIGUSR1 by `vault open` so it does not wait.
        GLib.timeout_add_seconds(2, self.refresh)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self.refresh)
        # A second pass over what the event handlers keep up to date, in case
        # one of their events was lost.
        GLib.timeout_add_seconds(30, self.tick)
        GLib.timeout_add_seconds(20, self.heartbeat)
        self.refresh()
        sd_notify("READY=1")
        GLib.MainLoop().run()

    @quietly(keep=True)
    def heartbeat(self):
        # From the main loop itself, so a guard stuck anywhere stops sending
        # it and systemd restarts it (WatchdogSec in modules/vault.nix).
        sd_notify("WATCHDOG=1")
        return GLib.SOURCE_CONTINUE

    @quietly(keep=True)
    def tick(self):
        if self.armed:
            strip_recent(True)
            hide_everything()
        self.report_health()
        self.ticks += 1
        if self.ticks % 10 == 0:
            self.supervise_timer()
        return GLib.SOURCE_CONTINUE

    def report_health(self):
        """What the check reads to know the guard is whole: whether the idle
        watch and, while the vault is open, the sleep delay are in place, and
        when it last ran."""
        write_atomic(HEALTH, json.dumps({
            "pid": os.getpid(), "beat": time.time(), "idle_watch": self.idle_id is not None,
            "inhibitor": (self.inhibitor is not None) if self.armed else None,
        }))

    def supervise_timer(self):
        # The check watches the guard; this is the guard watching the check,
        # every five minutes, so neither can stop without the other noticing.
        def active():
            return subprocess.run(["systemctl", "--user", "is-active", "--quiet", TIMER]).returncode == 0
        if active():
            resolve("timer-down")
            return
        subprocess.run(["systemctl", "--user", "start", TIMER], capture_output=True)
        if active():
            warn("timer-off", "Vault: the 2-minute check was off",
                 "vault-check.timer was not running, so nothing covered for the guard or cleared "
                 "traces. The guard has started it again.", incident=True)
        else:
            warn("timer-down", "Vault: the 2-minute check is not running",
                 "vault-check.timer would not start, so nothing covers for the guard or clears traces.",
                 fixed="The 2-minute check is running again.")

    def add_idle_watch(self):
        # Idle as GNOME counts it: no keyboard or mouse. A video playing holds
        # it off, the same way it keeps the screen on.
        try:
            reply = self.session.call_sync(
                "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                "org.gnome.Mutter.IdleMonitor", "AddIdleWatch", GLib.Variant("(t)", (IDLE_SECONDS * 1000,)),
                GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None)
            self.idle_id = reply.unpack()[0]
        except GLib.Error as error:
            log(f"no idle watch, so the idle lock is off: {error.message}")

    @quietly(keep=True)
    def refresh(self, *_):
        now = mounted()
        if now and not self.armed:
            self.arm()
        elif not now and self.armed:
            self.disarm()
        return GLib.SOURCE_CONTINUE

    def arm(self):
        self.armed = True
        self.inhibit()
        for path, _ in RECENT_LISTS:
            try:
                monitor = Gio.File.new_for_path(str(path)).monitor_file(Gio.FileMonitorFlags.NONE, None)
            except GLib.Error:
                continue
            monitor.connect("changed", self.on_recent_changed)
            self.recent.append(monitor)
        self.strip_now()
        self.watch_tree(str(MOUNT))
        self.report_health()
        if not OPENED.exists():
            write_atomic(OPENED, json.dumps({"sleep": sleep_offset()}))
        log("the vault is open; guarding it")

    def disarm(self):
        self.armed = False
        for monitor in [*self.dirs.values(), *self.recent]:
            monitor.cancel()
        self.dirs.clear()
        self.recent.clear()
        self.pending.clear()
        self.uninhibit()
        self.report_health()
        log("the vault is locked")

    def inhibit(self):
        # Held only while the vault is open. It makes logind wait for the lock
        # before suspending, so the key is gone before the laptop sleeps.
        try:
            reply, fds = self.system.call_with_unix_fd_list_sync(
                "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                "Inhibit", GLib.Variant("(ssss)", ("sleep", "Vault", "Lock the vault before sleeping", "delay")),
                GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, -1, None, None)
            self.inhibitor = fds.get(reply.unpack()[0])
        except GLib.Error as error:
            log(f"could not delay sleep, so the vault may lock just after it: {error.message}")

    def uninhibit(self):
        if self.inhibitor is not None:
            os.close(self.inhibitor)
            self.inhibitor = None

    def watch_tree(self, top):
        for directory, dirs, files in os.walk(top):
            hide_in(directory, dirs + files)
            self.watch(directory)

    def watch(self, directory):
        if directory in self.dirs:
            return
        try:
            monitor = Gio.File.new_for_path(directory).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
        except GLib.Error:
            return
        monitor.connect("changed", self.on_dir_changed, directory)
        self.dirs[directory] = monitor

    def forget(self, path):
        for directory in [d for d in self.dirs if in_tree(d, path)]:
            self.dirs.pop(directory).cancel()

    @quietly()
    def on_dir_changed(self, _monitor, file, other, event, directory):
        if event not in self.MOVES:
            return
        path = file.get_path() if file else None
        new = other.get_path() if other else None
        # Our own .hidden writes land here too, as a temp file renamed into
        # place. Only those are skipped: renaming a file to a dot name still
        # has to take its old name out of the list.
        names = [os.path.basename(p) for p in (path, new) if p]
        if names and all(n.startswith(".") for n in names):
            return
        if event in (Gio.FileMonitorEvent.DELETED, Gio.FileMonitorEvent.MOVED_OUT):
            if path:
                self.forget(path)
        elif event == Gio.FileMonitorEvent.RENAMED:
            if path:
                self.forget(path)
            if new and os.path.isdir(new):
                self.watch_tree(new)
        elif path and os.path.isdir(path):
            self.watch_tree(path)
        self.pending.add(directory)
        if self.flush_id is None:
            self.flush_id = GLib.timeout_add(100, self.flush)

    @quietly()
    def flush(self):
        self.flush_id = None
        for directory in sorted(self.pending):
            hide_in(directory)
        self.pending.clear()
        return GLib.SOURCE_REMOVE

    @quietly()
    def on_recent_changed(self, *_):
        if self.strip_id is None:
            self.strip_id = GLib.timeout_add(50, self.strip_now)

    @quietly()
    def strip_now(self):
        self.strip_id = None
        strip_recent(True)
        return GLib.SOURCE_REMOVE

    @quietly()
    def on_screensaver(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0]:
            self.lock_now("the screen locked")

    @quietly()
    def on_idle(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0] == self.idle_id:
            self.lock_now(f"you were idle for {IDLE_SECONDS // 60} minutes")

    @quietly()
    def on_sleep(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0]:
            self.lock_now("the laptop went to sleep")
        elif mounted():
            # Awake again and still open: the lock before sleep did not
            # happen or did not finish. Do it now.
            self.lock_now("the laptop slept while it was open")

    def lock_now(self, why):
        if not self.armed and not mounted():
            return
        try:
            # Never wait here: a `vault open` sitting at its password prompt
            # holds the lock, and queueing behind it would shut the vault the
            # moment it opened.
            result = lock(wait=False)
        except Exception as error:
            reason = str(error) if isinstance(error, RuntimeError) else failure(error)
            warn("lock-failed", "Vault: the vault could not lock",
                 f"It is still open ({reason}). Close the programs using it, then run `vault close`. "
                 "The 2-minute check also keeps trying.", fixed="The vault is locked now.")
            return
        finally:
            self.refresh()
        if result is not None:
            resolve("lock-failed")
            closed, report = result
            log(f"locked because {why}; closed {len(closed)} program(s)"
                + (f"; failed: {', '.join(problems(report))}" if problems(report) else ""))
            notify("Vault locked", f"Locked because {why}." + (f" Closed: {', '.join(closed)}." if closed else ""))


def no_core_dumps():
    """A crash dump is a copy of memory on disk, and memory here can hold a
    vault file name, or in gocryptfs the key. Non-dumpable stops the kernel
    writing one for this process whatever catches crashes; the zero core
    limit carries over to gocryptfs, which `vault open` starts. Non-dumpable
    also keeps other programs running as you out of this one's memory."""
    with contextlib.suppress(Exception):
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with contextlib.suppress(Exception):
        ctypes.CDLL(None, use_errno=True).prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE, 0


def main(argv):
    command = argv[1] if len(argv) > 1 else "help"
    if os.geteuid() == 0:
        die("run vault as yourself, not as root or with sudo")
    no_core_dumps()
    # Out of the vault, so this command never holds it open itself.
    os.chdir("/")
    if command != "guard":
        # A closed terminal or a kill ends the way Ctrl+C does, so anything
        # half done is put back first. (The guard is systemd's to stop.)
        for sig in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(sig, interrupted)
    if command == "open":
        open_vault(show="--no-window" not in argv)
    elif command == "add":
        add_command(argv[2:])
    elif command == "close":
        close_command(session_ending="--session-ending" in argv)
    elif command == "status":
        status()
    elif command == "check":
        return check(quiet="--quiet" in argv)
    elif command == "key":
        key_command()
    elif command == "guard":
        Guard().run()
    else:
        print(USAGE)
        return 0 if command in ("help", "-h", "--help") else 2
    return 0


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def finish(code):
    """Every way out ends here, with a sentence and never a traceback."""
    try:
        sys.exit(code())
    except SystemExit:
        raise
    except (Cancelled, KeyboardInterrupt) as stop:
        with contextlib.suppress(Exception):
            said = str(stop) if isinstance(stop, Cancelled) and str(stop) else "Cancelled."
            where = "open" if is_open() else "locked"
            print(f"\n{said} The vault is {where}.", file=sys.stderr)
        sys.exit(130)
    except BrokenPipeError:
        # Output piped into something that stopped reading, such as `head`.
        with contextlib.suppress(OSError):
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
    except OSError as error:
        # The system's own wording, never the file name the error carries.
        log(f"failed: {os.strerror(error.errno) if error.errno else type(error).__name__}")
        sys.exit(1)
    except Exception as error:  # noqa: BLE001  logged by type and line, never by message
        log(f"failed: {failure(error)}")
        sys.exit(1)


if __name__ == "__main__":
    finish(lambda: main(sys.argv))
