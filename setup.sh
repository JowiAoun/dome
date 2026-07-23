#!/usr/bin/env bash
# setup.sh — interactive machine setup for dome.
#
#   ./setup.sh                       guided TUI (whiptail; plain prompts as fallback)
#   ./setup.sh --defaults <host>     non-interactive: write user-config.nix from the
#                                    host's seed defaults (used by scripts/CI)
#   ./setup.sh --detect-apps         list apps the machine already has outside Nix
#   ./setup.sh --sync-apps-skip      refresh appsSkip in an existing user-config.nix
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
)

app_installed_outside_nix() { # <name>
  local want="$1" probe name desktops commands dir id cmd
  for probe in "${APP_PROBES[@]}"; do
    IFS='|' read -r name desktops commands <<< "$probe"
    [ "$name" = "$want" ] || continue
    for dir in "${SYSTEM_APP_DIRS[@]}"; do
      for id in $desktops; do
        [ -e "$dir/$id" ] && return 0
      done
    done
    for dir in "${SYSTEM_BIN_DIRS[@]}"; do
      for cmd in $commands; do
        [ -x "$dir/$cmd" ] && return 0
      done
    done
    return 1
  done
  return 1
}

detect_installed_apps() { # print one app name per line
  local probe name
  for probe in "${APP_PROBES[@]}"; do
    name="${probe%%|*}"
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
  local git_branch git_editor pref_shell pref_editor docker_engine docker_desktop
  git_branch="$(cfg_get gitDefaultBranch)"
  git_editor="$(cfg_get gitEditor)"
  pref_shell="$(cfg_get preferredShell)"
  pref_editor="$(cfg_get preferredEditor)"
  # System-layer switches: keep whatever is already configured, else the
  # template's defaults (engine on, desktop off).
  docker_engine="$(cfg_get dockerEngine)"
  docker_desktop="$(cfg_get dockerDesktop)"
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
}

# ── non-interactive modes ────────────────────────────────────────────────────
# Report which of the apps module's apps this machine already has elsewhere.
if [ "${1:-}" = "--detect-apps" ]; then
  detect_installed_apps
  exit 0
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
  write_config "$HOST" "$NAME" "$EMAIL"
  echo "[dome] wrote user-config.nix (host=$HOST)"
  printf 'Run the full install now (./install.sh --host %s)? (y/N): ' "$HOST"
  read -r go
  case "${go:-}" in
    y|Y) run_install "$HOST" ;;
    *) echo "[dome] done. Run ./install.sh --host $HOST when ready." ;;
  esac
fi
