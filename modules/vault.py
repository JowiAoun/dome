#!/usr/bin/env python3
"""vault: an encrypted folder at ~/Vault that locks itself and leaves no
trace of its files outside itself.

modules/vault.nix has the design. In short: gocryptfs keeps the files
encrypted in ~/.vault and shows them decrypted at a mount point under
/run/user, which ~/Vault links to. `vault guard` runs as a user service and
locks the vault when you go idle, lock the screen, suspend or log out.

This program never writes a vault file name outside the vault: not to the
journal, not to a state file, not to a notification. Its messages carry
counts and program names only.
"""

import contextlib
import fcntl
import json
import os
import re
import shlex
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

USAGE = """\
usage: vault open [--no-window]   unlock it (creating it the first time) and show it in Files
       vault close                close everything using it, then lock it
       vault status               say whether it is open and what is using it"""

HOME = Path.home()
UID = os.getuid()
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{UID}")
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")

# Every path can be moved with an environment variable. That is how this was
# tested against a throwaway vault without going near the real one.
CIPHER = Path(os.environ.get("VAULT_CIPHER") or HOME / ".vault")
LINK = Path(os.environ.get("VAULT_LINK") or HOME / "Vault")
MOUNT = Path(os.environ.get("VAULT_MOUNT") or RUNTIME / "vault")
STATE = Path(os.environ.get("VAULT_STATE") or RUNTIME / "vault-state")
SAVED = Path(os.environ.get("VAULT_SAVED") or HOME / ".local/state/vault/paused-settings.json")
IDLE_SECONDS = int(os.environ.get("VAULT_IDLE_SECONDS") or 15 * 60)

ROOTS = (str(MOUNT), str(LINK))
SELF = os.path.realpath(__file__)
APPS = STATE / "apps.json"

RECENT = DATA / "recently-used.xbel"
TEXT_EDITOR = DATA / "org.gnome.TextEditor"
THUMBNAILS = CACHE / "thumbnails"
DOCS = f"{RUNTIME}/doc/"

# Each recent list, and the program to close when it holds a vault file. None
# means read the program off the entry. Text Editor keeps a list of its own
# that GNOME's file history switch does not reach.
RECENT_LISTS = ((RECENT, None), (TEXT_EDITOR / "recently-used.xbel", "gnome-text-editor"))

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


def notify(title, body):
    with contextlib.suppress(OSError):
        subprocess.run(["notify-send", "-a", "Vault", "-i", "changes-prevent-symbolic", title, body],
                       capture_output=True)


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data if isinstance(data, bytes) else data.encode())
    os.replace(tmp, path)


def wait_for(condition, seconds):
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() > deadline:
            return False
        time.sleep(0.05)
    return True


# Paths

def in_vault(path):
    """The vault itself or anything in it, by either of its two paths."""
    return bool(path) and any(path == r or path.startswith(r + "/") for r in ROOTS)


def uri_path(uri):
    return Gio.File.new_for_uri(uri).get_path() if uri.startswith("file:") else None


def uri_in_vault(uri):
    return in_vault(uri_path(uri) or "")


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


def pause_history():
    # Already paused means the file holds the real originals. Overwriting it
    # would save our own "off" as the value to restore.
    if SAVED.exists():
        return
    write_atomic(SAVED, json.dumps({key: dconf("read", key) for key in PAUSED}))
    for key, value in PAUSED.items():
        dconf("write", key, value)


def resume_history():
    try:
        saved = json.loads(SAVED.read_text())
    except (OSError, ValueError):
        return
    for key, old in saved.items():
        if old:
            dconf("write", key, old)
        else:
            dconf("reset", key)
    SAVED.unlink(missing_ok=True)


def program_of(command):
    try:
        words = shlex.split(command.strip().strip("'\""))
    except ValueError:
        words = command.split()
    program = os.path.basename(words[0]) if words else ""
    return None if not program or program in LAUNCHERS else program


def strip_recent():
    """Remove vault files from the recent lists. Returns program to label for
    whatever added them, so a lock knows what to close."""
    apps = {}
    for path, owner in RECENT_LISTS:
        bookmarks = GLib.BookmarkFile()
        try:
            bookmarks.load_from_file(str(path))
        except GLib.Error:
            continue
        hits = [uri for uri in bookmarks.get_uris() if uri_in_vault(uri)]
        for uri in hits:
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
    return apps


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
    """A backstop. Thumbnails are off while the vault is open, so this should
    find nothing, unless an app ignores GNOME's switch."""
    removed = 0
    for png in THUMBNAILS.rglob("*.png"):
        uri = thumbnail_uri(png)
        if uri and uri_in_vault(uri):
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
    if not session.exists() or any(name_of(p) == "gnome-text-editor" for p in own_pids()):
        return 0
    try:
        state = GLib.Variant.new_from_bytes(GLib.VariantType("a{sv}"), GLib.Bytes.new(session.read_bytes()), False)
    except (OSError, GLib.Error):
        return 0
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


def unexport_documents(docs):
    """The document portal remembers every file it ever handed to a Flatpak
    app, by name, until told to forget it."""
    for doc_id, origin in docs.items():
        if in_vault(origin):
            subprocess.run(["flatpak", "document-unexport", "--doc-id", doc_id], capture_output=True)


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
    behind. Returns the names of the programs closed, or None when another
    vault command is busy. Safe to run on a locked vault: it then only does
    the clearing, which is also how a crash or a reboot gets cleaned up."""
    try:
        with held(wait):
            closed, docs = [], None
            if mounted() or gocryptfs_pids():
                apps = {**recall_apps(), **strip_recent()}
                docs = flatpak_documents()
                users = vault_users(apps, docs)
                close_all(users)
                closed = sorted(set(users.values()))
                if not unmount():
                    raise RuntimeError("it is still mounted")
            harden()
            strip_recent()
            sweep_thumbnails()
            scrub_text_editor()
            unexport_documents(flatpak_documents() if docs is None else docs)
            resume_history()
            APPS.unlink(missing_ok=True)
            return closed
    except BlockingIOError:
        return None


def create_vault():
    print("Creating your vault. Choose a password: you type it twice now, then once more to open it.")
    CIPHER.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any(CIPHER.iterdir()):
        die(f"{CIPHER} has files in it but no gocryptfs.conf, so it is not a vault. Move them out first")
    if subprocess.run(["gocryptfs", "-init", str(CIPHER)]).returncode != 0:
        die("the vault was not created")
    print("\nSave the master key above in your password manager. If you lose both it and your\n"
          "password, nothing in the vault can be recovered.\n")


def open_vault(show):
    if not sys.stdin.isatty():
        die("vault open asks for your password, so run it in a terminal")
    with held():
        if mounted() and gocryptfs_pids():
            print("The vault is already open at ~/Vault.")
        else:
            if mounted():
                # gocryptfs died and left its mount behind.
                subprocess.run(["fusermount3", "-u", "-z", str(MOUNT)], capture_output=True)
            if not (CIPHER / "gocryptfs.conf").exists():
                create_vault()
            # Before the mount, so there is no moment when a vault file is
            # visible and thumbnails are still on.
            pause_history()
            MOUNT.mkdir(parents=True, exist_ok=True)
            if any(MOUNT.iterdir()):
                resume_history()
                die(f"{MOUNT} should be empty while the vault is locked. Move what is in it out first")
            # fusermount3 refuses a mount point it cannot write to.
            os.chmod(MOUNT, 0o700)
            # A scope of its own, so closing this terminal does not take the
            # vault with it.
            subprocess.run(["systemd-run", "--user", "--scope", "--quiet", "--collect",
                            "--description=Vault (gocryptfs)", "--",
                            "gocryptfs", str(CIPHER), str(MOUNT)])
            if not mounted():
                harden()
                resume_history()
                die("the vault is still locked")
            hide_everything()
    subprocess.run(["systemctl", "--user", "kill", "--signal=SIGUSR1", "vault-guard.service"], capture_output=True)
    if not guard_running():
        log("vault-guard is not running, so nothing will lock the vault for you. Run `vault close` when done")
    if show and (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
        try:
            Gio.AppInfo.launch_default_for_uri(LINK.as_uri(), None)
        except GLib.Error:
            subprocess.run(["xdg-open", str(LINK)], capture_output=True)


def guard_running():
    return subprocess.run(["systemctl", "--user", "is-active", "--quiet", "vault-guard.service"]).returncode == 0


def close_command(session_ending):
    if session_ending:
        # ExecStop of the guard. A restart (make home) runs it too, and must
        # not lock a vault you are using. Only a session going down does.
        state = subprocess.run(["systemctl", "--user", "is-active", "graphical-session.target"],
                               capture_output=True, text=True).stdout.strip()
        if state == "active":
            return
    was_open = mounted()
    try:
        closed = lock()
    except RuntimeError as error:
        die(f"could not lock the vault: {error}")
    if not was_open:
        print("The vault is already locked.")
    else:
        print("Locked." + (f" Closed: {', '.join(closed)}." if closed else ""))
    if in_vault(os.environ.get("PWD", "")):
        print("This shell was inside the vault. Run `cd` to leave it.")


def status():
    if mounted():
        users = vault_users(recall_apps(), flatpak_documents())
        print("Open at ~/Vault.")
        if users:
            print("In use by: " + ", ".join(sorted(set(users.values()))) + ".")
    else:
        print("Locked.")
    if guard_running():
        print(f"It locks itself after {IDLE_SECONDS // 60} minutes idle, when the screen locks, "
              "before sleep and at logout.")
    else:
        print("Auto-lock is off: vault-guard is not running. See `systemctl --user status vault-guard`.")


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

    def run(self):
        if not mounted():
            lock()
        self.session.signal_subscribe(None, "org.gnome.ScreenSaver", "ActiveChanged", "/org/gnome/ScreenSaver",
                                      None, Gio.DBusSignalFlags.NONE, self.on_screensaver)
        self.session.signal_subscribe(None, "org.gnome.Mutter.IdleMonitor", "WatchFired",
                                      "/org/gnome/Mutter/IdleMonitor/Core", None, Gio.DBusSignalFlags.NONE,
                                      self.on_idle)
        self.system.signal_subscribe(None, "org.freedesktop.login1.Manager",
                                     "PrepareForSleep", "/org/freedesktop/login1", None,
                                     Gio.DBusSignalFlags.NONE, self.on_sleep)
        self.add_idle_watch()
        # Polled, and poked with SIGUSR1 by `vault open` so it does not wait.
        GLib.timeout_add_seconds(2, self.refresh)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self.refresh)
        self.refresh()
        GLib.MainLoop().run()

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
        log("the vault is open; guarding it")

    def disarm(self):
        self.armed = False
        for monitor in [*self.dirs.values(), *self.recent]:
            monitor.cancel()
        self.dirs.clear()
        self.recent.clear()
        self.pending.clear()
        self.uninhibit()
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

    def flush(self):
        self.flush_id = None
        for directory in sorted(self.pending):
            hide_in(directory)
        self.pending.clear()
        return GLib.SOURCE_REMOVE

    def on_recent_changed(self, *_):
        if self.strip_id is None:
            self.strip_id = GLib.timeout_add(50, self.strip_now)

    def strip_now(self):
        self.strip_id = None
        remember_apps(strip_recent())
        return GLib.SOURCE_REMOVE

    def on_screensaver(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0]:
            self.lock_now("the screen locked")

    def on_idle(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0] == self.idle_id:
            self.lock_now(f"you were idle for {IDLE_SECONDS // 60} minutes")

    def on_sleep(self, _conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0]:
            self.lock_now("the laptop went to sleep")

    def lock_now(self, why):
        if not self.armed and not mounted():
            return
        try:
            # Never wait here: a `vault open` sitting at its password prompt
            # holds the lock, and queueing behind it would shut the vault the
            # moment it opened.
            closed = lock(wait=False)
        except RuntimeError as error:
            notify("The vault could not lock", str(error))
            log(f"could not lock the vault: {error}")
            return
        finally:
            self.refresh()
        if closed is not None:
            log(f"locked because {why}; closed {len(closed)} program(s)")
            notify("Vault locked", f"Locked because {why}." + (f" Closed: {', '.join(closed)}." if closed else ""))


def in_tree(path, top):
    return path == top or path.startswith(top + "/")


def main(argv):
    # Out of the vault, so this command never holds it open itself.
    os.chdir("/")
    command = argv[1] if len(argv) > 1 else "help"
    if command == "open":
        open_vault(show="--no-window" not in argv)
    elif command == "close":
        close_command(session_ending="--session-ending" in argv)
    elif command == "status":
        status()
    elif command == "guard":
        Guard().run()
    else:
        print(USAGE)
        return 0 if command in ("help", "-h", "--help") else 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
