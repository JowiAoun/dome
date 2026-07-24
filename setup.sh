#!/usr/bin/env bash
# setup.sh — interactive machine setup for dome.
#
#   ./setup.sh                       guided TUI (whiptail; plain prompts as fallback)
#   ./setup.sh --defaults <host>     non-interactive: write user-config.nix from the
#                                    host's seed defaults (used by scripts/CI)
#   ./setup.sh --detect-apps         list apps the machine already has outside Nix
#   ./setup.sh --sync-apps-skip      refresh appsSkip in an existing user-config.nix
#   ./setup.sh --audit-apps          report duplicate apps / colliding .desktop ids
#   ./setup.sh --preflight-wipe [d]  what an erase would destroy that git cannot restore
#
# What it does: detects the machine (distro, hardware model, WSL/Codespaces),
# suggests a host profile, lets you toggle the language/tool modules, writes
# user-config.nix, and offers to run ./install.sh.
#
# Precedence for the module checklist seeds:
#   existing user-config.nix choices  >  hosts/<host>/setup-defaults.env  >  off
set -euo pipefail
cd "$(dirname "$0")"

MODULES=(python node java ai cloud apps)
# Toggle state; reassigned dynamically via `declare "m_<name>=..."`.
m_python=false m_node=false m_java=false m_ai=false m_cloud=false m_apps=false

# ── detection ────────────────────────────────────────────────────────────────
DISTRO=unknown
[ -r /etc/os-release ] && DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
KERNEL="$(uname -r)"
IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true
IS_CODESPACES=false
[ -n "${CODESPACES:-}${CODESPACE_NAME:-}" ] && IS_CODESPACES=true

SUGGESTED_HOST=generic
case "$MODEL" in *UX8406*) SUGGESTED_HOST=zenbook-duo ;; esac

# ── helpers ──────────────────────────────────────────────────────────────────
have_whiptail() { command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; }

cfg_get() { # <field> — read a value from user-config.nix; empty (success) if absent
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\";]+)\"?;.*/\1/p" user-config.nix 2>/dev/null | head -n1 || true
}

module_seed() { # <module> <host> — saved choice > host seed > false
  local saved seed_file
  saved="$(cfg_get "$1")"
  if [ "$saved" = true ] || [ "$saved" = false ]; then
    echo "$saved"
    return
  fi
  seed_file="hosts/$2/setup-defaults.env"
  if [ -f "$seed_file" ]; then
    local var val
    var="MODULE_$(echo "$1" | tr '[:lower:]' '[:upper:]')"
    val="$(sed -nE "s/^$var=(true|false)$/\1/p" "$seed_file" | head -n1)"
    [ -n "$val" ] && { echo "$val"; return; }
  fi
  echo false
}

cfg_get_list() { # <field> — read `field = [ ... ];` and return the inner text
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\[(.*)\];.*/\1/p" user-config.nix 2>/dev/null | head -n1 || true
}

# ── disk encryption ──────────────────────────────────────────────────────────
# True iff / sits on a dm-crypt layer. Walks the dependency chain upward so it
# still finds LUKS through LVM — the installer's "Use LVM and encryption"
# builds ext4 → LV → dm-crypt → partition, so the layer is two levels down.
# Deliberately needs no root: setup.sh runs as a normal user.
root_is_encrypted() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null)" || return 1
  [ -n "$src" ] || return 1
  lsblk -no TYPE --inverse "$src" 2>/dev/null | grep -qx crypt
}

# Kept to 16 lines: whiptail errors out rather than shrinking when the box is
# taller than the terminal, and 80x24 is still the floor worth assuming.
LUKS_WARNING="DISK ENCRYPTION — READ THIS ONCE, CAREFULLY

Your LUKS passphrase is the ONLY way into this disk.

Unlike BitLocker, nothing is escrowed: no recovery key sits in any
account, and no command will ever show you the passphrase again.
Forget it and every byte here is gone for good.

  1. Put it in a password manager AND on paper. Never keep the only
     copy on this machine — you cannot boot it to read it.

  2. Add a second, independent unlock so one lapse is not fatal; the
     system layer prints the exact 'cryptsetup luksAddKey' command.

  3. Keep a header backup on removable media (asked next). A damaged
     LUKS header stops the correct passphrase from working."

# ── "is this app already installed?" ─────────────────────────────────────────
# The apps module must never install a second copy of software the machine
# already has, nor take over its launcher. This is the shell half of the
# question; modules/apps.nix has the same table (probeDesktop/probeCommands)
# for the runtime check — keep the two in sync when adding an app.
#
# Only SYSTEM locations are searched. Looking inside ~/.nix-profile or
# ~/.local/share/applications would find the copies the module itself installed
# and mark them "already installed" on the next run, which would then uninstall
# them — a flip-flop that never settles.
SYSTEM_APP_DIRS=(
  /usr/share/applications
  /usr/local/share/applications
  /var/lib/snapd/desktop/applications
  /var/lib/flatpak/exports/share/applications
  "$HOME/.local/share/flatpak/exports/share/applications"
)
SYSTEM_BIN_DIRS=(/usr/bin /usr/local/bin /snap/bin /opt/bin)

# name|desktop entries|command names
APP_PROBES=(
  "brave|brave-browser.desktop brave.desktop com.brave.Browser.desktop brave_brave.desktop|brave-browser brave"
  "discord|discord.desktop com.discordapp.Discord.desktop discord_discord.desktop|discord Discord"
  "drawio|drawio.desktop com.jgraph.drawio.desktop.desktop drawio_drawio.desktop|drawio"
  "localsend|LocalSend.desktop localsend.desktop org.localsend.localsend_app.desktop localsend_localsend.desktop|localsend localsend_app"
  "bruno|bruno.desktop com.usebruno.Bruno.desktop bruno_bruno.desktop|bruno"
  "joplin|joplin.desktop joplin-desktop.desktop net.cozic.joplin_desktop.desktop joplin_joplin.desktop|joplin-desktop joplin"
  "obs-studio|com.obsproject.Studio.desktop obs-studio.desktop obs-studio_obs-studio.desktop|obs obs-studio"
  "thunderbird|thunderbird.desktop mozilla-thunderbird.desktop net.thunderbird.Thunderbird.desktop thunderbird_thunderbird.desktop|thunderbird"
  "zoom|Zoom.desktop zoom.desktop us.zoom.Zoom.desktop zoom-client_zoom-client.desktop|zoom zoom-us"
  "vscode|code.desktop visual-studio-code.desktop code_code.desktop com.visualstudio.code.desktop|code"
)

app_outside_nix() { # <name> — print where a non-Nix copy lives; 1 if there is none
  local want="$1" probe name desktops commands dir id cmd
  for probe in "${APP_PROBES[@]}"; do
    IFS='|' read -r name desktops commands <<< "$probe"
    [ "$name" = "$want" ] || continue
    for dir in "${SYSTEM_APP_DIRS[@]}"; do
      for id in $desktops; do
        if [ -e "$dir/$id" ]; then echo "$dir/$id"; return 0; fi
      done
    done
    for dir in "${SYSTEM_BIN_DIRS[@]}"; do
      for cmd in $commands; do
        if [ -x "$dir/$cmd" ]; then echo "$dir/$cmd"; return 0; fi
      done
    done
    return 1
  done
  return 1
}

app_installed_outside_nix() { # <name>
  app_outside_nix "$1" >/dev/null
}

app_from_nix() { # <name> — print where dome's own copy lives; 1 if not installed
  local want="$1" probe name desktops commands id cmd
  for probe in "${APP_PROBES[@]}"; do
    IFS='|' read -r name desktops commands <<< "$probe"
    [ "$name" = "$want" ] || continue
    for id in $desktops; do
      if [ -e "$HOME/.local/share/applications/$id" ]; then echo "$HOME/.local/share/applications/$id"; return 0; fi
      if [ -e "$HOME/.nix-profile/share/applications/$id" ]; then echo "$HOME/.nix-profile/share/applications/$id"; return 0; fi
    done
    for cmd in $commands; do
      if [ -x "$HOME/.nix-profile/bin/$cmd" ]; then echo "$HOME/.nix-profile/bin/$cmd"; return 0; fi
    done
    return 1
  done
  return 1
}

detect_installed_apps() { # print one app name per line
  local probe name brave_is_ours=""
  # With braveBrowser = true, /usr/bin/brave-browser is dome's OWN install from
  # system/78-brave.sh, not a foreign copy. Recording it in appsSkip would drop
  # its dash pin on the next run, so it is left out of the sweep entirely.
  if [ "$(cfg_get braveBrowser)" = true ]; then brave_is_ours=1; fi
  for probe in "${APP_PROBES[@]}"; do
    name="${probe%%|*}"
    if [ -n "$brave_is_ours" ] && [ "$name" = brave ]; then
      continue
    fi
    if app_installed_outside_nix "$name"; then
      echo "$name"
    fi
  done
}

apps_skip_literal() { # -> `"brave" "discord"` for the Nix list, or empty
  local name out=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    out="$out \"$name\""
  done < <(detect_installed_apps)
  printf '%s' "${out# }"
}

# ── duplicate audit ──────────────────────────────────────────────────────────
# The table above only covers apps dome knows about. This also does a generic
# sweep for the failure mode behind it: the same .desktop id existing in two
# places, which is what puts two icons of one app in the app grid.
audit_apps() {
  local probe name mine theirs shell_pid shell_dirs
  local dir sys f base hits
  local nix_dir="$HOME/.nix-profile/share/applications"
  local home_dir="$HOME/.local/share/applications"

  echo "== apps dome knows about =="
  printf '  %-12s %-9s %s\n' APP "FROM DOME" "ALSO OUTSIDE NIX"
  for probe in "${APP_PROBES[@]}"; do
    name="${probe%%|*}"
    mine="$(app_from_nix "$name" || true)"
    theirs="$(app_outside_nix "$name" || true)"
    printf '  %-12s %-9s %s\n' \
      "$name" \
      "$( [ -n "$mine" ] && echo yes || echo no )" \
      "${theirs:-no}"
  done
  echo
  echo "  Both columns yes = a duplicate. Fix it with ./setup.sh --sync-apps-skip"
  echo "  (records the app in appsSkip), then re-run ./setup.sh."

  # A colliding .desktop id only puts two icons in the app grid if gnome-shell
  # can see BOTH directories, so report what it actually has.
  echo
  echo "== desktop-entry collisions =="
  shell_pid="$(pgrep -u "$USER" -x gnome-shell 2>/dev/null | head -1 || true)"
  if [ -n "$shell_pid" ] && [ -r "/proc/$shell_pid/environ" ]; then
    shell_dirs="$(tr '\0' '\n' < "/proc/$shell_pid/environ" | sed -nE 's/^XDG_DATA_DIRS=(.*)/\1/p')"
    echo "  gnome-shell reads: $shell_dirs"
    echo "  (~/.local/share/applications is always read on top of those)"
    case "$shell_dirs" in
      *nix-profile*) ;;
      *) echo "  the Nix profile is NOT among them, so entries there are invisible to GNOME" ;;
    esac
  fi
  for dir in "$home_dir" "$nix_dir"; do
    echo "  $dir:"
    hits=0
    for f in "$dir"/*.desktop; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      for sys in "${SYSTEM_APP_DIRS[@]}"; do
        if [ -e "$sys/$base" ]; then
          printf '    %-32s also in %s\n' "$base" "$sys"
          hits=$((hits + 1))
        fi
      done
    done
    if [ "$hits" = 0 ]; then
      echo "    (no collisions)"
    fi
  done
  return 0
}

# ── pre-wipe gate check ──────────────────────────────────────────────────────
# Read-only. Answers one question: if this disk were erased in the next five
# minutes, what would be gone that no clone of the repo could bring back?
#
# Hard failures are things that are unrecoverable after the fact. Warnings are
# things that merely cost you time. Everything it cannot know — whether your
# 2FA lives only here, whether Windows still holds something — it names rather
# than pretends to check.
PF_FAIL=0
PF_WARN=0
pf_ok()   { printf '  \033[1;32mok  \033[0m %s\n' "$*"; }
pf_warn() { printf '  \033[1;33mwarn\033[0m %s\n' "$*"; PF_WARN=$((PF_WARN + 1)); }
pf_fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; PF_FAIL=$((PF_FAIL + 1)); }

preflight_wipe() { # [destination]
  local dest="${1:-}"

  echo "== dome pre-wipe check =="
  echo

  echo "git — anything not pushed dies with the disk"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local ahead remote_sha local_main
    ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
    if [ "$ahead" -gt 0 ]; then
      pf_fail "$ahead commit(s) on HEAD are not on origin/main — push before wiping"
      git log --oneline origin/main..HEAD 2>/dev/null | sed 's/^/         /'
    else
      pf_ok "no unpushed commits"
    fi
    # origin/main is only as fresh as the last fetch; ask the remote directly.
    remote_sha="$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)"
    local_main="$(git rev-parse origin/main 2>/dev/null || true)"
    if [ -n "$remote_sha" ] && [ -n "$local_main" ] && [ "$remote_sha" != "$local_main" ]; then
      pf_warn "origin/main is stale locally — run 'git fetch' and re-check"
    fi
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      pf_warn "uncommitted changes in the working tree:"
      git status --short 2>/dev/null | sed 's/^/         /'
    else
      pf_ok "working tree clean"
    fi
  else
    pf_warn "not a git repository — skipping git checks"
  fi
  echo

  echo "not in git — must be captured by the backup"
  if [ -f user-config.nix ]; then
    pf_ok "user-config.nix present (gitignored, so a clone cannot restore it)"
  else
    pf_fail "no user-config.nix — nothing to preserve, ./setup.sh will re-ask everything"
  fi
  local key found=0
  for key in "$HOME"/.ssh/id_*; do
    case "$key" in *.pub) continue ;; esac
    [ -e "$key" ] && found=1
  done
  if [ "$found" = 1 ]; then pf_ok "SSH private key present in ~/.ssh"
  else pf_warn "no SSH private key in ~/.ssh — you will need to re-key GitHub"; fi
  if [ -d "$HOME/.local/share/keyrings" ]; then
    pf_ok "login keyring present (decrypts Brave's saved passwords)"
  else
    pf_warn "no ~/.local/share/keyrings — saved browser passwords may not survive"
  fi
  if [ -d /etc/NetworkManager/system-connections ]; then
    pf_ok "NetworkManager profiles exist — backup.sh captures them with sudo (your WiFi password)"
  fi
  echo

  echo "backup blockers"
  # Names, not command lines — see the note in migrate/backup.sh.
  if pgrep -x 'brave|brave-browser|\.brave-wrapped|firefox' >/dev/null 2>&1; then
    pf_fail "a browser is running — backup.sh will refuse (live SQLite profiles)"
  else
    pf_ok "no browser running"
  fi
  echo

  echo "destination"
  local root_disk dest_disk
  root_disk="$(lsblk -npo PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -n1)"
  if [ -n "$dest" ]; then
    if [ ! -d "$dest" ]; then
      pf_fail "$dest does not exist"
    elif [ ! -w "$dest" ]; then
      pf_fail "$dest is not writable"
    else
      dest_disk="$(lsblk -npo PKNAME "$(findmnt -no SOURCE --target "$dest" 2>/dev/null)" 2>/dev/null | head -n1)"
      if [ "$dest_disk" = "$root_disk" ]; then
        pf_fail "$dest is on the same physical disk as / — it dies with the wipe"
      else
        pf_ok "$dest is on $dest_disk, separate from $root_disk ($(df -h --output=avail "$dest" | tail -n1 | tr -d ' ') free)"
      fi
    fi
  else
    pf_warn "no destination given — candidates on other disks:"
    findmnt -rno TARGET,SOURCE -t vfat,exfat,ntfs,ext4 2>/dev/null | while read -r t s; do
      case "$t" in /|/boot*|/snap*|/sys*|/proc*) continue ;; esac
      [ "$(lsblk -npo PKNAME "$s" 2>/dev/null | head -n1)" = "$root_disk" ] && continue
      printf '         %s (%s free)\n' "$t" "$(df -h --output=avail "$t" 2>/dev/null | tail -n1 | tr -d ' ')"
    done
  fi
  echo

  echo "what an erase would destroy on $root_disk"
  lsblk -no NAME,SIZE,FSTYPE,LABEL "$root_disk" 2>/dev/null | sed 's/^/         /'
  echo

  echo "cannot be checked from here — confirm yourself"
  echo "         · any 2FA / TOTP seed that exists only on this machine"
  echo "         · anything still on the Windows partition (BitLocker: opaque, and final)"
  echo "         · the LUKS passphrase you are about to choose is written down OFF this machine"
  echo

  printf '== %d failure(s), %d warning(s) ==\n' "$PF_FAIL" "$PF_WARN"
  if [ "$PF_FAIL" -gt 0 ]; then
    echo "Resolve the failures before wiping."
    return 1
  fi
  echo "Clear to back up:  make backup DEST=<destination>"
  return 0
}

merged_apps_skip() { # -> a complete Nix list literal for appsSkip
  # Union of what is already in user-config.nix and what is detected now, so a
  # name you added by hand is never dropped, and an app installed since the
  # last run is picked up.
  local existing detected item merged=""
  existing="$(cfg_get_list appsSkip)"
  detected="$(apps_skip_literal)"
  for item in $existing $detected; do
    case " $merged " in
      *" $item "*) ;;
      *) merged="$merged $item" ;;
    esac
  done
  merged="${merged# }"
  if [ -n "$merged" ]; then
    printf '[ %s ]' "$merged"
  else
    printf '[ ]'
  fi
}

list_hosts() { # every hosts/<name>/ directory is a selectable profile
  local d
  for d in hosts/*/; do
    basename "$d"
  done
}

run_install() { # <host> — run install.sh as a CHILD (never exec: exec would
                # close the terminal window when install.sh exits), teed to a log
  local host="$1" log="$HOME/dome-install.log"
  echo "[dome] running ./install.sh --host $host  (logging to $log)"
  set +e
  ./install.sh --host "$host" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "[dome] install exited with status $rc — see $log (last lines below):" >&2
    tail -n 15 "$log" >&2
    return "$rc"
  fi
}

write_config() { # <host> <name> <email> then module vars m_python.. in env
  local host="$1" name="$2" email="$3"
  local username homedir
  username="${USER:-$(id -un)}"
  homedir="${HOME:-/home/$username}"
  if [ "$IS_CODESPACES" = true ]; then
    username=codespace
    homedir=/home/codespace
  fi
  # Read the preference fields BEFORE the heredoc. `cat > user-config.nix` sets
  # up its redirection first and truncates the file, so a $(cfg_get ...) inside
  # the heredoc body would read the now-empty file and every saved preference
  # would silently reset to the hard-coded default below on each re-run.
  local git_branch git_editor pref_shell pref_editor docker_engine docker_desktop claude_desktop brave_browser brave_policy open_whispr
  git_branch="$(cfg_get gitDefaultBranch)"
  git_editor="$(cfg_get gitEditor)"
  pref_shell="$(cfg_get preferredShell)"
  pref_editor="$(cfg_get preferredEditor)"
  # System-layer switches: keep whatever is already configured, else the
  # template's defaults (engine on, desktop off).
  docker_engine="$(cfg_get dockerEngine)"
  docker_desktop="$(cfg_get dockerDesktop)"
  claude_desktop="$(cfg_get claudeDesktop)"
  brave_browser="$(cfg_get braveBrowser)"
  brave_policy="$(cfg_get braveManagedPolicy)"
  open_whispr="$(cfg_get openWhispr)"
  # Carried through untouched. There is deliberately no prompt for this:
  # renaming a machine is a one-off, not something to be re-asked on every
  # re-run. Edit hostName in user-config.nix (or pass HOST_NAME=... for a
  # scripted run) and the system layer applies it.
  local host_name="${HOST_NAME-$(cfg_get hostName)}"
  # Same override-or-keep pattern: the interactive flow exports LUKS_HEADER_DIR
  # after asking, and a scripted run keeps whatever is already on disk.
  local luks_header_dir="${LUKS_HEADER_DIR-$(cfg_get luksHeaderBackupDir)}"
  local apps_skip
  apps_skip="$(merged_apps_skip)"
  cat > user-config.nix <<EOF
{
  # Generated by setup.sh on $(date +%F). Re-run ./setup.sh to change choices.
  name = "$name";
  email = "$email";

  # Module selections
  modules = {
    python = $m_python;
    node = $m_node;
    java = $m_java;
    ai = $m_ai;
    cloud = $m_cloud;
    apps = $m_apps;
  };

  # Apps already installed outside Nix - the apps module leaves these alone
  appsSkip = $apps_skip;

  # System-layer switches (read by system/*.sh, not by Nix)
  dockerEngine = $docker_engine;
  dockerDesktop = $docker_desktop;
  claudeDesktop = $claude_desktop;
  openWhispr = $open_whispr;
  braveBrowser = $brave_browser;
  braveManagedPolicy = $brave_policy;

  # Where system/95-luks.sh writes the LUKS header backup. Must be removable
  # media: a header backup stored on the encrypted disk cannot be used to
  # recover that disk. Empty = skip the backup (the warning still prints).
  luksHeaderBackupDir = "$luks_header_dir";

  # Machine name (static + pretty + /etc/hosts). Empty = leave it alone.
  hostName = "$host_name";

  # Host profile - selects hosts/<name> for BOTH layers (Nix + system/)
  hostProfile = "$host";

  # Environment detection
  environment = {
    isCodespaces = $IS_CODESPACES;
    isWSL = $IS_WSL;
    username = "$username";
    homeDirectory = "$homedir";
  };

  # Additional user preferences
  gitDefaultBranch = "$git_branch";
  gitEditor = "$git_editor";

  # Development environment preferences
  preferredShell = "$pref_shell";
  preferredEditor = "$pref_editor";
}
EOF
  # Backfill preference fields from the template when no previous config existed.
  sed -i 's/gitDefaultBranch = "";/gitDefaultBranch = "main";/' user-config.nix
  sed -i 's/gitEditor = "";/gitEditor = "vim";/' user-config.nix
  sed -i 's/preferredShell = "";/preferredShell = "zsh";/' user-config.nix
  sed -i 's/preferredEditor = "";/preferredEditor = "vim";/' user-config.nix
  # Same for the system-layer switches. These are bare booleans, so an empty
  # cfg_get leaves `dockerEngine = ;`, which is not valid Nix — the backfill is
  # what makes a first run produce a parseable file.
  sed -i 's/dockerEngine = ;/dockerEngine = true;/' user-config.nix
  sed -i 's/dockerDesktop = ;/dockerDesktop = false;/' user-config.nix
  sed -i 's/claudeDesktop = ;/claudeDesktop = true;/' user-config.nix
  sed -i 's/braveBrowser = ;/braveBrowser = true;/' user-config.nix
  sed -i 's/braveManagedPolicy = ;/braveManagedPolicy = true;/' user-config.nix
  sed -i 's/openWhispr = ;/openWhispr = true;/' user-config.nix
}

# ── non-interactive modes ────────────────────────────────────────────────────
# Report which of the apps module's apps this machine already has elsewhere.
if [ "${1:-}" = "--detect-apps" ]; then
  detect_installed_apps
  exit 0
fi

# Read-only report: which apps exist where, and which .desktop ids collide.
if [ "${1:-}" = "--audit-apps" ]; then
  audit_apps
  exit 0
fi

# Read-only report: what would be lost if this disk were erased right now.
if [ "${1:-}" = "--preflight-wipe" ]; then
  preflight_wipe "${2:-}"
  exit $?
fi

# Refresh only the appsSkip field of an existing user-config.nix. Run it after
# installing (or removing) one of these apps from apt/snap/flatpak; install.sh
# calls it on every run.
if [ "${1:-}" = "--sync-apps-skip" ]; then
  [ -f user-config.nix ] || { echo "no user-config.nix yet — run ./setup.sh first" >&2; exit 1; }
  skip="$(merged_apps_skip)"
  if grep -qE '^[[:space:]]*appsSkip = ' user-config.nix; then
    sed -i "s|^\(\s*\)appsSkip = .*;|\1appsSkip = $skip;|" user-config.nix
  elif grep -qE '^[[:space:]]*# Host profile' user-config.nix; then
    # Predates the field: insert it above the hostProfile block, comment and
    # all, so the existing comment stays attached to the setting it describes.
    sed -i "s|^\([[:space:]]*\)# Host profile|\1# Apps already installed outside Nix - the apps module leaves these alone\n\1appsSkip = $skip;\n\n\1# Host profile|" user-config.nix
  else
    sed -i "s|^\(\s*\)hostProfile = |\1appsSkip = $skip;\n\n\1hostProfile = |" user-config.nix
  fi
  echo "[dome] appsSkip = $skip"
  exit 0
fi

if [ "${1:-}" = "--defaults" ]; then
  HOST="${2:?usage: ./setup.sh --defaults <host>}"
  [ -d "hosts/$HOST" ] || { echo "unknown host profile: $HOST (have: $(list_hosts | tr '\n' ' '))" >&2; exit 1; }
  for m in "${MODULES[@]}"; do
    declare "m_$m=$(module_seed "$m" "$HOST")"
  done
  NAME="$(cfg_get name)"; EMAIL="$(cfg_get email)"
  NAME="${NAME:-$(git config --global user.name 2>/dev/null || true)}"
  EMAIL="${EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
  write_config "$HOST" "${NAME:-Jowi Aoun}" "${EMAIL:-83415433+JowiAoun@users.noreply.github.com}"
  echo "[dome] wrote user-config.nix (host=$HOST, non-interactive)"
  exit 0
fi

# ── interactive mode ─────────────────────────────────────────────────────────
DETECT_TEXT="Detected machine:

  Distro:      $DISTRO
  Hardware:    $VENDOR $MODEL
  Kernel:      $KERNEL
  WSL:         $IS_WSL
  Codespaces:  $IS_CODESPACES

Suggested host profile: $SUGGESTED_HOST"

if have_whiptail; then
  whiptail --title "dome setup" --msgbox "$DETECT_TEXT" 16 70

  # host profile radiolist, suggestion pre-selected
  HOST_ITEMS=()
  while IFS= read -r h; do
    state=OFF
    [ "$h" = "$SUGGESTED_HOST" ] && state=ON
    HOST_ITEMS+=("$h" "hosts/$h" "$state")
  done < <(list_hosts)
  HOST="$(whiptail --title "dome setup" --radiolist \
    "Host profile for this machine:" 14 60 "${#HOST_ITEMS[@]}" \
    "${HOST_ITEMS[@]}" 3>&1 1>&2 2>&3)" || { echo "aborted"; exit 1; }

  # module checklist, seeded per precedence
  MOD_ITEMS=()
  for m in "${MODULES[@]}"; do
    state=OFF
    [ "$(module_seed "$m" "$HOST")" = true ] && state=ON
    MOD_ITEMS+=("$m" "" "$state")
  done
  CHOSEN="$(whiptail --title "dome setup" --checklist \
    "Modules to enable (space toggles, enter confirms):" 15 60 "${#MODULES[@]}" \
    "${MOD_ITEMS[@]}" 3>&1 1>&2 2>&3)" || { echo "aborted"; exit 1; }
  for m in "${MODULES[@]}"; do
    declare "m_$m=false"
  done
  for m in $CHOSEN; do
    m="${m%\"}"; m="${m#\"}"
    declare "m_$m=true"
  done

  NAME_DEFAULT="$(cfg_get name)"; NAME_DEFAULT="${NAME_DEFAULT:-$(git config --global user.name 2>/dev/null || echo 'Jowi Aoun')}"
  EMAIL_DEFAULT="$(cfg_get email)"; EMAIL_DEFAULT="${EMAIL_DEFAULT:-$(git config --global user.email 2>/dev/null || echo '83415433+JowiAoun@users.noreply.github.com')}"
  NAME="$(whiptail --title "dome setup" --inputbox "Your name (git commits):" 10 60 "$NAME_DEFAULT" 3>&1 1>&2 2>&3)" || exit 1
  EMAIL="$(whiptail --title "dome setup" --inputbox "Your email (git commits):" 10 60 "$EMAIL_DEFAULT" 3>&1 1>&2 2>&3)" || exit 1

  # Set either way, so write_config's ${LUKS_HEADER_DIR-...} keeps an existing
  # value on an unencrypted machine instead of blanking it.
  LUKS_HEADER_DIR="$(cfg_get luksHeaderBackupDir)"
  if root_is_encrypted; then
    whiptail --title "dome setup — disk encryption" --scrolltext --msgbox "$LUKS_WARNING" 22 74
    LUKS_HEADER_DIR="$(whiptail --title "dome setup — disk encryption" --inputbox \
      "LUKS header backup directory.

Removable media only — a header backup stored on the encrypted disk
can never be used to recover it. Blank to skip." \
      14 72 "$LUKS_HEADER_DIR" 3>&1 1>&2 2>&3)" || exit 1
  fi
  export LUKS_HEADER_DIR

  SUMMARY="host:    $HOST
name:    $NAME
email:   $EMAIL
modules:"
  for m in "${MODULES[@]}"; do
    v="m_$m"
    SUMMARY="$SUMMARY
  $m = ${!v}"
  done
  whiptail --title "dome setup — confirm" --yesno "$SUMMARY

Write user-config.nix?" 18 60 || { echo "aborted, nothing written"; exit 1; }

  write_config "$HOST" "$NAME" "$EMAIL"

  RUN_NOW=no
  whiptail --title "dome setup" --yesno \
    "Run the full install now?\n\nsystem layer (sudo) -> Nix -> home-manager.\nOutput is logged to ~/dome-install.log" 12 64 && RUN_NOW=yes
  # whiptail has torn down here — back on the normal terminal, so sudo/Nix
  # prompts below are visible and the shell survives (no exec).
  echo "[dome] wrote user-config.nix (host=$HOST)"
  if [ "$RUN_NOW" = yes ]; then
    run_install "$HOST"
  else
    echo "[dome] done. Run ./install.sh --host $HOST when ready."
  fi
else
  # plain-prompt fallback (no whiptail or no TTY-attached UI possible)
  echo "== dome setup =="
  echo "$DETECT_TEXT"
  echo
  printf 'Host profile [%s] (options: %s): ' "$SUGGESTED_HOST" "$(list_hosts | tr '\n' ' ')"
  read -r HOST
  HOST="${HOST:-$SUGGESTED_HOST}"
  [ -d "hosts/$HOST" ] || { echo "unknown host profile: $HOST" >&2; exit 1; }
  for m in "${MODULES[@]}"; do
    seed="$(module_seed "$m" "$HOST")"
    printf 'Enable module %-7s [%s] (y/n): ' "$m" "$seed"
    read -r ans
    case "${ans:-}" in
      y|Y) declare "m_$m=true" ;;
      n|N) declare "m_$m=false" ;;
      *) declare "m_$m=$seed" ;;
    esac
  done
  NAME_DEFAULT="$(cfg_get name)"; NAME_DEFAULT="${NAME_DEFAULT:-$(git config --global user.name 2>/dev/null || echo 'Jowi Aoun')}"
  EMAIL_DEFAULT="$(cfg_get email)"; EMAIL_DEFAULT="${EMAIL_DEFAULT:-$(git config --global user.email 2>/dev/null || echo '83415433+JowiAoun@users.noreply.github.com')}"
  printf 'Name [%s]: ' "$NAME_DEFAULT"; read -r NAME; NAME="${NAME:-$NAME_DEFAULT}"
  printf 'Email [%s]: ' "$EMAIL_DEFAULT"; read -r EMAIL; EMAIL="${EMAIL:-$EMAIL_DEFAULT}"
  LUKS_HEADER_DIR="$(cfg_get luksHeaderBackupDir)"
  if root_is_encrypted; then
    echo
    echo "$LUKS_WARNING"
    echo
    printf 'LUKS header backup dir (removable media, blank to skip) [%s]: ' "$LUKS_HEADER_DIR"
    read -r luks_in
    [ -n "$luks_in" ] && LUKS_HEADER_DIR="$luks_in"
  fi
  export LUKS_HEADER_DIR
  write_config "$HOST" "$NAME" "$EMAIL"
  echo "[dome] wrote user-config.nix (host=$HOST)"
  printf 'Run the full install now (./install.sh --host %s)? (y/N): ' "$HOST"
  read -r go
  case "${go:-}" in
    y|Y) run_install "$HOST" ;;
    *) echo "[dome] done. Run ./install.sh --host $HOST when ready." ;;
  esac
fi
