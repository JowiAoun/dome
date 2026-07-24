#!/usr/bin/env bash
# mkdesktop — turn a locally-installed binary or AppImage into a proper,
# searchable GNOME application, the way a .deb would.
#
#   mkdesktop <executable> [--name "War Thunder"] [--icon <file>] \
#             [--wmclass <class>] [--categories "Game;"] [--terminal]
#
# Why this exists: software installed from a .deb ships a .desktop entry in
# /usr/share/applications, so GNOME indexes it for search and the dash. A bare
# binary or AppImage you just downloaded ships nothing (or, like the War Thunder
# launcher, writes a BROKEN entry), so it never appears in search and runs only
# by double-clicking the file. This writes a correct entry to
# ~/.local/share/applications so the app behaves like any other.
#
# What a correct entry needs, and what each piece fixes:
#   Exec=  absolute path to the binary          → launches from search
#   Path=  its directory                        → binaries that load data files
#                                                 relative to CWD still work
#   Icon=  absolute path to an image            → a real icon in grid and dash
#   StartupWMClass=  the window's class/app_id  → the RUNNING window groups under
#                                                 that icon instead of a generic one
#
# StartupWMClass is the one thing that cannot be guessed ahead of time — it is
# whatever the app calls itself at the window level, and you can only read it off
# a live window. If you omit it and the dash shows a generic icon while the app
# is open, find the class and re-run with --wmclass (recipe printed at the end).
set -euo pipefail

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

name="" icon="" wmclass="" categories="" terminal=false exe=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)       name="$2";       shift 2 ;;
    --icon)       icon="$2";       shift 2 ;;
    --wmclass)    wmclass="$2";    shift 2 ;;
    --categories) categories="$2"; shift 2 ;;
    --terminal)   terminal=true;   shift   ;;
    -h|--help)    usage; exit 0 ;;
    -*) echo "mkdesktop: unknown option: $1" >&2; usage; exit 2 ;;
    *)  exe="$1"; shift ;;
  esac
done
[ -n "$exe" ] || { usage; exit 2; }

# Resolve to an absolute path — .desktop Exec/Icon do NOT expand ~, $HOME or a
# relative path, so everything written below must be absolute.
exe="$(readlink -f -- "$exe")" || { echo "mkdesktop: not found: $exe" >&2; exit 1; }
[ -e "$exe" ] || { echo "mkdesktop: not found: $exe" >&2; exit 1; }
[ -x "$exe" ] || { chmod +x -- "$exe"; echo "mkdesktop: made executable: $exe"; }
dir="$(dirname -- "$exe")"
base="$(basename -- "$exe")"

[ -n "$name" ] || name="$base"
# Filename slug: lowercase, spaces to dashes, keep it filesystem-safe.
slug="$(printf '%s' "$name" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"
[ -n "$slug" ] || slug="$base"

# Icon auto-detect: the first image sitting next to the binary, preferring the
# formats GNOME renders best. .ico works too — GdkPixbuf has an ICO loader.
if [ -z "$icon" ]; then
  for ext in png svg ico xpm; do
    for cand in "$dir"/*."$ext"; do
      [ -e "$cand" ] || continue
      icon="$cand"; break 2
    done
  done
fi

apps="$HOME/.local/share/applications"
mkdir -p "$apps"
out="$apps/$slug.desktop"

{
  echo "[Desktop Entry]"
  echo "Version=1.0"
  echo "Type=Application"
  echo "Name=$name"
  echo "Path=$dir"
  echo "Exec=$exe"
  [ -n "$icon" ] && echo "Icon=$icon"
  echo "Terminal=$terminal"
  echo "Categories=${categories:-Utility;}"
  echo "StartupNotify=true"
  [ -n "$wmclass" ] && echo "StartupWMClass=$wmclass"
} > "$out"

# Validate before announcing success — an invalid Exec is silently dropped from
# search, which is the whole failure this tool exists to prevent.
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$out" && echo "mkdesktop: valid ✓"
fi
# Refresh the MIME/app cache so it shows up in search now, not at next login.
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
echo "mkdesktop: wrote $out"

[ -n "$icon" ] || echo "mkdesktop: no image found next to $base — pass --icon <file> for a proper icon"
if [ -z "$wmclass" ]; then
  cat <<EOF
mkdesktop: no --wmclass set. If the dash shows a generic icon while the app is
           open, read its window class off the live window and re-run with it:
             Wayland: WAYLAND_DEBUG=1 "$exe" 2>&1 | grep -m1 set_app_id
             X11:     xprop WM_CLASS      # then click the window
           then:  mkdesktop "$exe" --name "$name" --wmclass <value>
EOF
fi
