#!/usr/bin/env bash
# 83-qt-runtime.sh — the two things the Qt online installer leaves broken on
# Ubuntu: a hand-installed Qt 6 whose GUI apps refuse to start, and launchers
# with no icon.
#
# Part one is the libraries, below. Part two is at the bottom of this file: the
# installer's own .desktop entries name icons it never copies into the tree it
# created for them. Both are the same shape — software installed outside any
# package manager, expecting a system nobody set up for it.
#
# THE SYMPTOM, verbatim from Qt Creator 20.0.0 (Qt 6.11.1) on a fresh 24.04:
#
#   qt.qpa.plugin: From 6.5.0, xcb-cursor0 or libxcb-cursor0 is needed to load
#     the Qt xcb platform plugin.
#   Could not load the Qt platform plugin "xcb" in "" even though it was found.
#   This application failed to start because no Qt platform plugin could be
#     initialized. Reinstalling the application may fix this problem.
#
# "even though it was found" is the confusing part, and reinstalling — the one
# thing the message suggests — cannot help: the plugin file is present and
# intact, it just links against a library Ubuntu does not install by default.
#
#   $ ldd /opt/Qt/Tools/QtCreator/lib/Qt/plugins/platforms/libqxcb.so | grep 'not found'
#           libxcb-cursor.so.0 => not found
#
# Qt 6.5 added a hard dependency on libxcb-cursor for cursor themes on X11. The
# Qt online installer does not bundle it and does not check for it, because it
# has no package manager to ask — which is exactly the gap this layer fills.
#
# WHY IT HITS A WAYLAND MACHINE AT ALL. This session is Wayland, and Qt ships a
# working wayland plugin, but Qt DELIBERATELY ignores it under GNOME:
#
#   Warning: Ignoring WAYLAND_DISPLAY on Gnome.
#            Use QT_QPA_PLATFORM=wayland to run on Wayland anyway.
#
# So Qt apps here run on XWayland through xcb, and the xcb plugin is the one
# that needs the library. Forcing QT_QPA_PLATFORM=wayland does start the app
# (measured — that is how `qtcreator -version` was got out of it before the fix)
# and gives crisper fractional scaling, but it is Qt's own decision to avoid
# that path on GNOME, so it is left alone here rather than overridden for every
# Qt app on the machine.
#
# NO SWITCH: this detects a hand-installed Qt and does nothing when there is
# none. The package is ~30 KB, is a dependency of Qt itself rather than a
# preference, and there is no version of "I have Qt installed and would like it
# not to start".
#
# Deliberately NOT chased, because neither affects the IDE:
#   libtiff.so.5   Qt's TIFF image plugin wants the Ubuntu 22.04 soname; noble
#                  ships libtiff6. Costs TIFF thumbnails, nothing else, and
#                  there is no libtiff5 in noble to install.
#   libpq / libmysqlclient / libodbc / libclntsh / libfbclient / libmimerapi
#                  optional Qt SQL driver plugins. Missing ones are simply not
#                  loaded; they matter only to an app that talks to that
#                  database, and then its own package should pull them in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

# Where the Qt online installer puts things: /opt/Qt for a system-wide install,
# ~/Qt for a per-user one (its own default). Both are checked, plus a qtcreator
# that is simply on PATH.
QT_DIRS=(/opt/Qt /opt/qt)
USER_HOME=""
if user="$(target_user)" && [ -n "$user" ]; then
  USER_HOME="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$USER_HOME" ] && QT_DIRS+=("$USER_HOME/Qt" "$USER_HOME/qt")
fi

QT_ROOT=""
for d in "${QT_DIRS[@]}"; do
  if [ -d "$d" ]; then
    QT_ROOT="$d"
    break
  fi
done
# A qtcreator on PATH, as .../Qt/Tools/QtCreator/bin/qtcreator — four levels up
# is the install root the icons hang off.
if [ -z "$QT_ROOT" ] && command -v qtcreator >/dev/null 2>&1; then
  QT_ROOT="$(cd "$(dirname "$(readlink -f "$(command -v qtcreator)")")/../../.." && pwd)"
fi

if [ -z "$QT_ROOT" ]; then
  log "no hand-installed Qt found (/opt/Qt, ~/Qt) — nothing to do"
  exit 0
fi

log "hand-installed Qt found at $QT_ROOT"

# The xcb platform plugin's runtime dependencies, taken from the binaries rather
# than from a forum post — every soname the shipped Qt actually links:
#
#   $ objdump -p .../lib/Qt/**/*.so | awk '/NEEDED/{print $2}' | sort -u | grep xcb
#
# libxcb-cursor0 is the only one Ubuntu does not already install for the
# desktop. libxkbcommon-x11-0 is listed because it IS linked and is missing on a
# minimal install, where it produces the same "could not load xcb" message with
# no hint attached; on a normal desktop it is already there and this is a no-op.
#
# libxcb-xinerama0 is the package every answer on the internet adds here. It is
# deliberately absent: nothing in this Qt references it (the command above finds
# no libxcb-xinerama soname at all), and `ldd libqxcb.so` reports exactly one
# unresolved library on this machine — libxcb-cursor.so.0 — so it is the whole
# fix rather than one item in a shotgun list.
ensure_pkg libxcb-cursor0 libxkbcommon-x11-0

log "Qt's xcb platform plugin has its libraries — Qt Creator and friends can start"

# ── the missing icons ────────────────────────────────────────────────────────
# The Qt installer DOES write launchers — into /usr/local/share/applications
# when it was run as root, ~/.local/share/applications otherwise — and they are
# fine apart from one thing:
#
#   Icon=QtProject-qtcreator      (Qt Creator)
#   Icon=QtIcon                   (Qt Maintenance Tool)
#
# Those are ICON THEME NAMES, not paths, so they are looked up in the icon
# theme search path. The installer even creates the whole directory layout to
# hold them — /usr/local/share/icons/hicolor/{16x16,...,512x512}/apps — and then
# NEVER COPIES THE ICONS IN. Verified on this machine: eight directories, zero
# files. The entries therefore work, launch correctly and show a generic cog
# forever, which reads as "the launcher is broken" when nothing about it is.
#
# So this copies Qt's own icons into the tree Qt made for them. Deliberately NOT
# a hand-written .desktop with an absolute Icon= path, and NOT an mkdesktop
# entry: either of those adds a SECOND Qt Creator to the app grid next to the
# vendor's, which is worse than a grey icon. Fixing the icon where the vendor's
# own entry already looks for it leaves exactly one launcher — with its
# MimeType, its %F and its StartupWMClass intact.
install_icon() { # <src> <dst> <owner>
  local src="$1" dst="$2" owner="$3"
  [ -f "$src" ] || return 0
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would install $dst (owner $owner)"
    mark_change
    return 0
  fi
  # The owner matters: this runs as root, and a per-user Qt install puts its
  # icons under $HOME. Writing those as root:root would leave the user unable to
  # replace or remove their own files, and the Maintenance Tool unable to clean
  # up after itself on uninstall.
  install -D -o "$owner" -g "$owner" -m 0644 "$src" "$dst"
  mark_change
  log "installed icon: $dst"
}

# Where to put them: beside the launcher that asks for them. A root install
# writes to /usr/local/share, a per-user one to ~/.local/share, and this handles
# whichever is actually there rather than assuming.
icon_bases=()
for apps_dir in /usr/local/share/applications /usr/share/applications \
                ${USER_HOME:+"$USER_HOME/.local/share/applications"}; do
  [ -d "$apps_dir" ] || continue
  # Match the THEME-NAME form only — `Icon=QtProject-qtcreator` with nothing
  # after it. An entry carrying an absolute path (`Icon=/opt/Qt/.../QtProject-qtcreator.png`)
  # already resolves and needs nothing from us; matching the bare string would
  # treat it as broken and install icons next to a launcher that never asks for
  # them. And `[ -n "$(find ...)" ]` rather than a pipe into `grep -q`, which
  # lib.sh's pipefail turns into a coin flip.
  if [ -n "$(find "$apps_dir" -maxdepth 1 -name '*.desktop' \
              -exec grep -lE '^Icon=(QtProject-qtcreator|QtIcon)[[:space:]]*$' {} + 2>/dev/null)" ]; then
    icon_bases+=("$(dirname "$apps_dir")/icons/hicolor")
  fi
done

icons_changed=0
if [ ${#icon_bases[@]} -eq 0 ]; then
  log "no Qt launcher with a missing icon found — nothing to fill in"
else
  before_changes=$CHANGES
  for base in "${icon_bases[@]}"; do
    # Root owns what lives under /usr; the user owns what lives in their home.
    owner=root
    if [ -n "$USER_HOME" ] && [ -n "$user" ]; then
      case "$base" in "$USER_HOME"/*) owner="$user" ;; esac
    fi
    for size in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
      install_icon "$QT_ROOT/Tools/QtCreator/share/icons/hicolor/$size/apps/QtProject-qtcreator.png" \
                   "$base/$size/apps/QtProject-qtcreator.png" "$owner"
    done
    # The Maintenance Tool ships one 256x256 PNG, outside any hicolor layout.
    install_icon "$QT_ROOT/icons/QtIcon.png" "$base/256x256/apps/QtIcon.png" "$owner"
  done
  [ "$CHANGES" -ne "$before_changes" ] && icons_changed=1
fi

# Tell the desktop the theme moved. New files inside a subdirectory do not
# change the mtime of the theme directory that GTK and gnome-shell put their
# file monitors on, so without this nothing they watch has visibly changed and
# the icons appear only at the next login. Touching it is what a .deb's dpkg
# trigger achieves as a side effect of rewriting icon-theme.cache.
#
# Deliberately NOT writing an icon-theme.cache here. GTK prefers a cache over
# scanning the directory, and this tree is shared: a cache we generate now would
# hide any icon another installer adds later, until something regenerates it.
# The lookup already works by scanning (checked with Gtk.IconTheme.lookup_icon
# in a fresh process, which resolves both names to these files), so a cache buys
# nothing here and takes on a stale-icon failure mode.
if [ "$icons_changed" = 1 ] && [ "$DRY_RUN" != 1 ]; then
  for base in "${icon_bases[@]}"; do
    touch "$base" "$(dirname "$base")" 2>/dev/null || true
  done
  for apps_dir in /usr/local/share/applications ${USER_HOME:+"$USER_HOME/.local/share/applications"}; do
    [ -d "$apps_dir" ] || continue
    command -v update-desktop-database >/dev/null 2>&1 &&
      update-desktop-database "$apps_dir" 2>/dev/null || true
  done
  log "icons installed. GNOME resolves an icon NAME once per session, so if the"
  log "  app grid still shows a generic cog, log out and back in — that is the"
  log "  only reliable refresh on Wayland, where gnome-shell cannot be restarted."
fi

# The installer leaves everything it creates under /usr/local/share mode 0777 —
# not just the two top directories but every hicolor size directory below them.
# A world-writable directory that GNOME reads .desktop files and icons out of
# means any local process can drop in (or swap) a launcher that every user of
# this machine sees and may click. Qt has no reason to need it.
#
# `chmod o-w` rather than a flat 755: it removes exactly the bit that is wrong
# and leaves anything else about the mode alone, so re-running cannot broaden
# permissions on something this script did not create.
for d in /usr/local/share/applications /usr/local/share/icons; do
  [ -d "$d" ] || continue
  ww="$(find "$d" \( -type d -o -type f \) -perm -o+w -print 2>/dev/null || true)"
  [ -n "$ww" ] || continue
  n="$(printf '%s\n' "$ww" | wc -l | tr -d ' ')"
  log "tightening $n world-writable path(s) under $d (the Qt installer creates them 0777)"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would chmod o-w on those paths"
  else
    find "$d" \( -type d -o -type f \) -perm -o+w -exec chmod o-w {} + 2>/dev/null || true
  fi
  mark_change
done

log "  Qt's launchers come from the installer itself; this only fills in the icons it forgot"
