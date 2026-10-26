"""Game power: Performance mode while a game runs, your own choice the rest of
the time. Like Windows' Game Mode, with nothing to switch by hand.

It asks power-profiles-daemon, the service behind GNOME's Power Mode menu, to
HOLD the performance profile. A hold is not a setting: when it is released, the
laptop goes back to whatever mode you had picked. It is also tied to this
process, so if this crashes or is stopped, the hold goes with it.

A game is any of these:
  - a game Steam started. Steam starts each one through its reaper helper,
    whose command line names the game: `reaper SteamLaunch AppId=230410 -- ...`.
    That covers every Steam game, Proton or native, with no setup per game.
  - a program that GameMode has registered, such as Minecraft started from
    CurseForge (modules/gaming.nix starts it through gamemoderun).
  - a game that is neither, by its program name (GAME_PROGRAMS).

If you pick a mode yourself while a game runs, the daemon drops the hold, and
this leaves your choice alone until that game has ended.
"""

import os
import re
import sys
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

APP_ID = "dome-game-power"
EVERY_SECONDS = 3
PPD = ("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
       "org.freedesktop.UPower.PowerProfiles")
GAMEMODE = ("com.feralinteractive.GameMode", "/com/feralinteractive/GameMode",
            "com.feralinteractive.GameMode")
# Games that are neither started by Steam nor registered with GameMode, by the
# name of their program.
GAME_PROGRAMS = {"sober": "Roblox"}
# Where Steam keeps its library: the snap, the .deb and the Flatpak.
STEAM_ROOTS = [Path.home() / p / "steamapps" for p in (
    "snap/steam/common/.local/share/Steam",
    ".local/share/Steam",
    ".var/app/com.valvesoftware.Steam/.local/share/Steam",
)]
UID = os.getuid()


def log(message):
    print(message, flush=True)


def steam_name(app_id):
    """The game's name from Steam's own record of it, or its number."""
    for root in STEAM_ROOTS:
        try:
            text = (root / f"appmanifest_{app_id}.acf").read_text(errors="replace")
        except OSError:
            continue
        match = re.search(r'"name"\s+"([^"]*)"', text)
        if match:
            return match[1]
    return f"Steam game {app_id}"


def running_games():
    """The names of the games running now, from your own processes."""
    found = set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if os.stat(f"/proc/{pid}").st_uid != UID:
                continue
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            comm = Path(f"/proc/{pid}/comm").read_text().strip()
        except OSError:
            continue
        if comm in GAME_PROGRAMS:
            found.add(GAME_PROGRAMS[comm])
        if b"SteamLaunch" in argv:
            for arg in argv:
                if arg.startswith(b"AppId=") and arg[6:].isdigit() and arg[6:] != b"0":
                    found.add(steam_name(arg[6:].decode()))
    return found


class GamePower:
    def __init__(self):
        self.system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
        self.session = Gio.bus_get_sync(Gio.BusType.SESSION)
        self.cookie = None
        # The daemon's bus name when the hold was taken. A hold that is gone
        # while the daemon is the same one was dropped because you picked a
        # mode; one that went with a restarted daemon is taken again.
        self.owner = None
        self.overridden = False
        self.games = set()

    def ppd_owner(self):
        try:
            return self.system.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                         "org.freedesktop.DBus", "GetNameOwner",
                                         GLib.Variant("(s)", (PPD[0],)), GLib.VariantType("(s)"),
                                         Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
        except GLib.Error:
            return None

    def get(self, bus, target, prop):
        name, path, iface = target
        return bus.call_sync(name, path, "org.freedesktop.DBus.Properties", "Get",
                             GLib.Variant("(ss)", (iface, prop)), GLib.VariantType("(v)"),
                             Gio.DBusCallFlags.NO_AUTO_START, 5000, None).unpack()[0]

    def gamemode_clients(self):
        try:
            return int(self.get(self.session, GAMEMODE, "ClientCount"))
        except GLib.Error:
            return 0

    def still_held(self):
        try:
            holds = self.get(self.system, PPD, "ActiveProfileHolds")
        except GLib.Error:
            return False
        return any(h.get("ApplicationId") == APP_ID for h in holds)

    def hold(self, reason):
        name, path, iface = PPD
        try:
            self.cookie = self.system.call_sync(
                name, path, iface, "HoldProfile",
                GLib.Variant("(sss)", ("performance", reason, APP_ID)), GLib.VariantType("(u)"),
                Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        except GLib.Error as error:
            log(f"could not hold Performance: {error.message}")
            return
        self.owner = self.ppd_owner()
        log(f"{reason}: Performance mode held")

    def release(self):
        cookie, self.cookie = self.cookie, None
        name, path, iface = PPD
        try:
            self.system.call_sync(name, path, iface, "ReleaseProfile", GLib.Variant("(u)", (cookie,)),
                                  None, Gio.DBusCallFlags.NONE, 5000, None)
        except GLib.Error:
            pass
        log("no game running: back to your own power mode")

    def tick(self):
        games = running_games()
        if self.gamemode_clients():
            games.add("a GameMode game")
        if games != self.games and games:
            log("running: " + ", ".join(sorted(games)))
        self.games = games

        if not games:
            if self.cookie is not None:
                self.release()
            self.overridden = False
            return True
        if self.cookie is not None and not self.still_held():
            self.cookie = None
            if self.ppd_owner() == self.owner:
                self.overridden = True
                log("you picked a power mode yourself: leaving it until the game ends")
        if self.cookie is None and not self.overridden:
            self.hold(", ".join(sorted(games)) + " is running")
        return True


def main():
    if sys.argv[1:] == ["--list"]:
        for game in sorted(running_games()):
            print(game)
        return
    power = GamePower()
    power.tick()
    GLib.timeout_add_seconds(EVERY_SECONDS, power.tick)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
