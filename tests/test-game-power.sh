#!/usr/bin/env bash
# Behavioural tests for modules/game-power.py: when it holds Performance mode,
# when it lets go, and when it leaves your own choice alone. The D-Bus calls are
# replaced with stand-ins, so this never changes the real power mode, and it
# runs with any python3 (gi is stubbed).
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$repo/modules" <<'EOF'
import subprocess, sys, time, types

# gi is only used to reach D-Bus, which every test below replaces.
gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository"); repo.Gio = repo.GLib = types.SimpleNamespace()
sys.modules.update({"gi": gi, "gi.repository": repo})
sys.path.insert(0, sys.argv[1])
import importlib.util
spec = importlib.util.spec_from_file_location("game_power", f"{sys.argv[1]}/game-power.py")
gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)
gp.log = lambda m: None

passed = failed = 0
def expect(name, ok):
    global passed, failed
    if ok: passed += 1; print(f"  ok    {name}")
    else: failed += 1; print(f"  FAIL  {name}")

class Fake(gp.GamePower):
    """The daemon, as far as the logic sees it."""
    def __init__(self):
        self.cookie = None; self.owner = None; self.overridden = False; self.games = set()
        self.now = set(); self.clients = 0; self.held = False; self.daemon = ":1.1"; self.holds = 0
    def ppd_owner(self): return self.daemon
    def gamemode_clients(self): return self.clients
    def still_held(self): return self.held
    def hold(self, reason):
        self.cookie = 7; self.owner = self.daemon; self.held = True; self.holds += 1
    def release(self):
        self.cookie = None; self.held = False

real_games = gp.running_games
def tick(p):
    gp.running_games = lambda: set(p.now)
    p.tick()

print("test-game-power: holding and letting go")
p = Fake(); tick(p)
expect("nothing running: no hold", not p.held)
p.now = {"Warframe"}; tick(p)
expect("a game starts: Performance is held", p.held)
tick(p)
expect("and held once, not again every few seconds", p.holds == 1)
p.now = set(); tick(p)
expect("the game ends: the hold is let go", not p.held)
p.clients = 1; tick(p)
expect("a GameMode game counts as a game", p.held)
p.clients = 0; tick(p)

print("test-game-power: your own choice wins")
p.now = {"Warframe"}; tick(p)
p.held = False; tick(p)
expect("you pick a mode mid-game: it is not taken back", not p.held and p.overridden)
tick(p)
expect("not on the next check either", not p.held)
p.now = set(); tick(p)
p.now = {"Warframe"}; tick(p)
expect("the next game holds Performance again", p.held)
p.held = False; p.daemon = ":1.9"; tick(p)
expect("a restarted daemon dropped it: it is taken again", p.held and not p.overridden)

print("test-game-power: what counts as a game")
gp.running_games = real_games
fake = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "SteamLaunch", "AppId=4242", "--"])
other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "SteamLaunch", "AppId=0"])
time.sleep(0.3)
games = gp.running_games()
expect("a game Steam started is found, by its number when Steam has no record of it", "Steam game 4242" in games)
expect("Steam's own AppId=0 is not a game", "Steam game 0" not in games)
fake.kill(); other.kill(); fake.wait(); other.wait()
expect("and it is gone once the game exits", "Steam game 4242" not in gp.running_games())

print(f"test-game-power: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
EOF
