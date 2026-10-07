#!/usr/bin/env bash
# Tests for modules/vault.py, against a throwaway vault in a throwaway home
# with its own D-Bus session, and so its own dconf: the real vault, the real
# Recent list and the real settings are never touched. Parts of the vault are
# broken on purpose to show the rest still holds.
#
# Needs FUSE, a systemd user session and the vault installed (make home). It
# skips anywhere else, so `make test` is safe on any machine.
set -u

if [ -z "${VAULT_TEST_INNER:-}" ]; then
  installed="$(command -v vault 2>/dev/null)" || { echo "test-vault: skipped, vault is not installed (make home)"; exit 0; }
  [ -c /dev/fuse ] && [ -u /usr/bin/fusermount3 ] || { echo "test-vault: skipped, no FUSE here"; exit 0; }
  command -v dbus-run-session >/dev/null && command -v script >/dev/null \
    || { echo "test-vault: skipped, needs dbus-run-session and script"; exit 0; }
  systemctl --user show-environment >/dev/null 2>&1 || { echo "test-vault: skipped, no systemd user session"; exit 0; }
  # Name the config: a Nix dbus-run-session looks in /etc, Ubuntu keeps it in /usr/share.
  conf=/usr/share/dbus-1/session.conf; [ -f "$conf" ] || conf=/etc/dbus-1/session.conf
  T="$(mktemp -d /tmp/vault-test.XXXXXX)"
  # The test home is set BEFORE the bus starts, so everything the bus starts
  # runs in it too, dconf above all. Set after, the dconf service the bus
  # starts would write to the real settings database.
  exec env VAULT_TEST_INNER="$installed" VAULT_TEST_DIR="$T" REAL_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}" \
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_CACHE_HOME="$T/home/.cache" dbus-run-session --config-file="$conf" -- bash "$0" "$@"
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0
ok()     { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

T="$VAULT_TEST_DIR"
export VAULT_MOUNT="$XDG_RUNTIME_DIR/vault-test-$$" VAULT_STATE="$XDG_RUNTIME_DIR/vault-test-$$-state"
export VAULT_GUARD_UNIT="vault-guard-test-$$.service" VAULT_IDLE_SECONDS=900
M="$VAULT_MOUNT"
mkdir -p "$HOME" "$T/bin" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME/thumbnails/normal"

cleanup() {
  for job in $(jobs -p); do kill -9 "$job" 2>/dev/null; done
  pkill -9 -f "gocryptfs.*$HOME/.vault" 2>/dev/null
  fusermount3 -u -z "$M" 2>/dev/null
  chmod 700 "$M" 2>/dev/null
  rm -rf "$T" "$M" "$VAULT_STATE"
}
trap cleanup EXIT

# The installed wrapper, pointed at this checkout's vault.py, with stand-ins
# for flatpak (no portal on this private bus) and notify-send (logged).
sed -e "s#/nix/store/[^ ]*-vault.py#$repo/modules/vault.py#" -e '/VAULT_IDLE_SECONDS/d' \
    -e "s#^export PATH=\"#export PATH=\"$T/bin:#" "$VAULT_TEST_INNER" > "$T/bin/vault-test"
sed -e 's#^exec \([^ ]*\) .*#exec \1 "$@"#' "$T/bin/vault-test" > "$T/bin/py"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/flatpak"
printf '#!/bin/sh\necho "$*" >> %s/notified\necho 42\n' "$T" > "$T/bin/notify-send"
chmod +x "$T/bin/"*
v()  { "$T/bin/vault-test" "$@"; }
dconf_bin="$(grep -o '/nix/store/[^:"]*-dconf-[^:"/]*/bin' "$T/bin/vault-test" | head -1)/dconf"
dconf() { env -u LD_LIBRARY_PATH "$dconf_bin" "$@"; }

# Prove the isolation before writing anything that matters: a canary written
# here must show up in the test database and not in the real one.
dconf write /vault-test/canary "'$$'"
if [ "$(dconf read /vault-test/canary)" != "'$$'" ] || [ -n "$(XDG_CONFIG_HOME="$REAL_CONFIG" dconf read /vault-test/canary)" ]; then
  dconf reset /vault-test/canary
  echo "test-vault: aborted, dconf writes are not isolated from the real settings"
  exit 1
fi
py() { "$T/bin/py" "$@"; }
gocryptfs="$(grep -o '/nix/store/[^:"]*-gocryptfs-[^:"/]*/bin' "$T/bin/vault-test" | head -1)"

# The scrubbers wait for a running app, and the lock closes apps that put a
# vault file in a recent list, so the real ones must not be running.
busy="$(py - <<'EOF'
import os
names = {"vlc": "VLC", "soffice.bin": "LibreOffice", "audacity": "Audacity", "xournalpp": "Xournal++", "gnome-text-editor": "Text Editor"}
found = set()
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        name = os.path.basename(os.readlink(f"/proc/{pid}/exe").removesuffix(" (deleted)"))
    except OSError:
        continue
    if name.startswith(".") and name.endswith("-wrapped"):
        name = name[1:-8]
    if name in names:
        found.add(names[name])
print(", ".join(sorted(found)))
EOF
)"
if [ -n "$busy" ]; then echo "test-vault: skipped, close these first: $busy"; exit 0; fi

printf 'testpass\n' > "$T/pw"
mkdir -m 700 "$HOME/.vault"
"$gocryptfs/gocryptfs" -init -q -passfile "$T/pw" "$HOME/.vault" >/dev/null
open_vault() { (sleep 1.5; printf 'testpass\n') | script -qec "$T/bin/vault-test open --no-window" /dev/null >/dev/null 2>&1; }
mounted()    { findmnt -no FSTYPE "$M" >/dev/null 2>&1; }
thumbs()     { dconf read /org/gnome/desktop/thumbnailers/disable-all; }
alive()      { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status"; }

# A vault file in a recent list, the way an image viewer adds one.
recent() { py - "$1" "$2" "$3" <<'EOF'
import sys, gi; gi.require_version("GLib", "2.0"); from gi.repository import GLib
path, uri, prog = sys.argv[1:]
b = GLib.BookmarkFile()
try: b.load_from_file(path)
except GLib.Error: pass
b.add_application(uri, "Dummy", f"'{prog} %u'")
b.to_file(path)
EOF
}
thumbnail() { py - "$1" "$2" <<'EOF'
import sys, struct, zlib
path, uri = sys.argv[1:]
chunk = lambda k, d: struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d) & 0xffffffff)
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
                       + chunk(b"tEXt", b"Thumb::URI\0" + uri.encode()) + chunk(b"IDAT", zlib.compress(b"\0\0")) + chunk(b"IEND", b""))
EOF
}

echo "test-vault: opening"
open_vault
expect "vault open mounts the vault" mounted
expect "thumbnails are off while it is open" '[ "$(thumbs)" = true ]'
expect "the open is recorded for the sleep check" '[ -f "$VAULT_STATE/opened.json" ]'
expect "gocryptfs, which holds the key, can never dump its memory to disk" 'grep -Eq "^Max core file size +0 +0 " /proc/$(pgrep -f "gocryptfs.*$HOME/.vault" | head -1)/limits'

echo "test-vault: the guard keeps files hidden and Recent clean as things happen"
v guard 2>"$T/guard.log" & guard=$!
sleep 1.5
mkdir "$M/Taxes"; echo a > "$M/photo.jpg"; echo b > "$M/Taxes/return.pdf"; sleep 1
expect "a new file is hidden" 'grep -qx photo.jpg "$M/.hidden"'
expect "a file in a new folder is hidden" 'grep -qx return.pdf "$M/Taxes/.hidden"'
recent "$XDG_DATA_HOME/recently-used.xbel" "file://$HOME/Vault/photo.jpg" dummyviewer; sleep 1
expect "a Recent entry for a vault file is removed as it is written" '! grep -q "Vault/photo.jpg" "$XDG_DATA_HOME/recently-used.xbel"'
expect "the program that added it is remembered for the lock" 'grep -q dummyviewer "$VAULT_STATE/apps.json"'
W="$HOME/.local/state/vault"
v check --quiet
expect "a guard without GNOME's idle monitor (none on this test bus) raises a warning" 'grep -q guard-idle "$W/warnings.json"'

echo "test-vault: with the guard dead, vault check covers for it"
kill -9 "$guard"; wait "$guard" 2>/dev/null
echo c > "$M/later.txt"
recent "$XDG_DATA_HOME/recently-used.xbel" "file://$HOME/Vault/later.txt" dummyviewer
recent "$XDG_DATA_HOME/recently-used.xbel" "file:///tmp/elsewhere.txt" dummyviewer
dconf write /org/gtk/gtk4/settings/file-chooser/last-folder-uri "'file://$M/Taxes'"
dconf write /org/gtk/settings/file-chooser/last-folder-uri "'file:///tmp'"
thumbnail "$XDG_CACHE_HOME/thumbnails/normal/vault.png" "file://$HOME/Vault/photo.jpg"
thumbnail "$XDG_CACHE_HOME/thumbnails/normal/other.png" "file:///tmp/other.jpg"
dconf write /org/gnome/desktop/thumbnailers/disable-all false

vlc="$HOME/.var/app/org.videolan.VLC/config/vlc"; mkdir -p "$vlc"
printf '[qt] # Qt interface\n#qt-recentplay=1\n#qt-recentplay-filter=\n#qt-continue=1\n' > "$vlc/vlcrc"
printf '[General]\nfiledialog-path=%s/Taxes\nkeep-me=1\n\n[RecentsMRL]\nlist=file:///tmp/a.mp4\ntimes=0\n' "$HOME/Vault" > "$vlc/vlc-qt-interface.conf"

lo="$XDG_CONFIG_HOME/libreoffice/4/user"; mkdir -p "$lo/backup"; echo copy > "$lo/backup/return_0.odt"
cat > "$lo/registrymodifications.xcu" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>
<item oor:path="/org.openoffice.Office.Histories/Histories/org.openoffice.Office.Histories:HistoryInfo['PickList']/ItemList"><node oor:name="file:///tmp/notes.odt" oor:op="replace"><prop oor:name="Title" oor:op="fuse"><value>notes</value></prop></node></item>
<item oor:path="/org.openoffice.Office.Histories/Histories/org.openoffice.Office.Histories:HistoryInfo['PickList']/OrderList"><node oor:name="0" oor:op="replace"><prop oor:name="HistoryItemRef" oor:op="fuse"><value>file:///tmp/notes.odt</value></prop></node></item>
<item oor:path="/org.openoffice.Office.Recovery/RecoveryList"><node oor:name="recovery_item_1" oor:op="replace"><prop oor:name="OrgURL" oor:op="fuse"><value>file://$M/Taxes/return.odt</value></prop><prop oor:name="TempURL" oor:op="fuse"><value>file://$lo/backup/return_0.odt</value></prop></node></item>
</oor:items>
EOF

aud="$XDG_DATA_HOME/Audacity/Audacity4"; mkdir -p "$aud/logs" "$XDG_CONFIG_HOME/Audacity"
printf '["%s/song.aup4", "/tmp/other.aup4"]\n' "$M" > "$aud/recent_files.json"
printf 'opened %s/song.aup4\n' "$HOME/Vault" > "$aud/logs/a.log"; echo "nothing here" > "$aud/logs/b.log"
printf '[project]\npaths\\lastprojects=%s/song.aup4\nkeep=1\n' "$M" > "$XDG_CONFIG_HOME/Audacity/Audacity4.ini"

mkdir -p "$XDG_CONFIG_HOME/xournalpp" "$XDG_CACHE_HOME/xournalpp/metadata"
printf '<settings>\n<property name="lastOpenPath" value="%s/Taxes"/>\n<property name="lastSavePath" value="/tmp"/>\n</settings>\n' "$HOME/Vault" > "$XDG_CONFIG_HOME/xournalpp/settings.xml"
printf '%s/Taxes/notes.xopp\n3\n' "$M" > "$XDG_CACHE_HOME/xournalpp/metadata/1.metadata"

v check > "$T/check1.txt"; status=$?
expect "the check reports the dead guard (no test unit to restart) and fails" '[ $status -eq 1 ] && grep -q "FAILED   vault-guard" "$T/check1.txt"'
expect "a file added while the guard was dead is hidden" 'grep -qx later.txt "$M/.hidden"'
expect "a failure raises a critical notification" 'grep -q -- "-u critical.*Vault: auto-lock is not working" "$T/notified"'
expect "and is listed for new terminals" 'grep -q "auto-lock is not working" "$W/warnings.txt"'
expect "a new terminal shows it" 'bash "$repo/modules/vault-banner.sh" | grep -q "⚠ Vault: auto-lock is not working"'
expect "a warning is not repeated on every check" '[ "$(grep -c "auto-lock is not working" "$T/notified")" -eq 1 ]'
expect "a missing ~/Vault link is put back" '[ "$(readlink "$HOME/Vault")" = "$M" ]'
expect "Vault is added to ~/.hidden" 'grep -qx Vault "$HOME/.hidden"'
expect "Recent: vault entries removed, others kept" '! grep -q "Vault/later.txt" "$XDG_DATA_HOME/recently-used.xbel" && grep -q elsewhere.txt "$XDG_DATA_HOME/recently-used.xbel"'
expect "a file chooser's last folder in the vault is reset" '[ -z "$(dconf read /org/gtk/gtk4/settings/file-chooser/last-folder-uri)" ]'
kept="'file:///tmp'"
expect "a file chooser's last folder elsewhere is kept" '[ "$(dconf read /org/gtk/settings/file-chooser/last-folder-uri)" = "$kept" ]'
expect "a vault thumbnail is deleted, another kept" '[ ! -e "$XDG_CACHE_HOME/thumbnails/normal/vault.png" ] && [ -e "$XDG_CACHE_HOME/thumbnails/normal/other.png" ]'
expect "thumbnails are switched back off while open" '[ "$(thumbs)" = true ]'
expect "VLC: recent media and resume switched off" 'grep -qx qt-recentplay=0 "$vlc/vlcrc" && grep -qx qt-continue=0 "$vlc/vlcrc" && grep -q "^#qt-recentplay-filter=" "$vlc/vlcrc"'
expect "VLC: recent list emptied, vault folder dropped, the rest kept" '! grep -q RecentsMRL "$vlc/vlc-qt-interface.conf" && ! grep -q Vault "$vlc/vlc-qt-interface.conf" && grep -q keep-me "$vlc/vlc-qt-interface.conf"'
expect "LibreOffice: recent documents off and emptied" 'grep -q "PickListSize" "$lo/registrymodifications.xcu" && ! grep -q HistoryInfo "$lo/registrymodifications.xcu" && ! grep -q notes.odt "$lo/registrymodifications.xcu"'
expect "LibreOffice: recovery copy of a vault file deleted, other settings kept" '[ ! -e "$lo/backup/return_0.odt" ] && ! grep -q RecoveryList "$lo/registrymodifications.xcu" && grep -q FirstRun "$lo/registrymodifications.xcu"'
expect "LibreOffice: settings still parse" 'py -c "import xml.etree.ElementTree as E; E.parse(\"$lo/registrymodifications.xcu\")"'
expect "LibreOffice: the header is untouched (oor:type=\"xs:string\" needs its xs namespace)" 'head -2 "$lo/registrymodifications.xcu" | grep -q "xmlns:xs="'
cp "$lo/registrymodifications.xcu" "$T/xcu-once"; v check >/dev/null 2>&1
expect "a second check changes nothing more" 'cmp -s "$T/xcu-once" "$lo/registrymodifications.xcu"'
expect "Audacity: recent files cleaned, others kept" '! grep -q song "$aud/recent_files.json" && grep -q other.aup4 "$aud/recent_files.json"'
expect "Audacity: log naming the vault deleted, other kept" '[ ! -e "$aud/logs/a.log" ] && [ -e "$aud/logs/b.log" ]'
expect "Audacity: last project path dropped, other settings kept" '! grep -q lastprojects "$XDG_CONFIG_HOME/Audacity/Audacity4.ini" && grep -q keep=1 "$XDG_CONFIG_HOME/Audacity/Audacity4.ini"'
expect "Xournal++: last folder in the vault cleared, other kept" 'grep -q "lastOpenPath\" value=\"\"" "$XDG_CONFIG_HOME/xournalpp/settings.xml" && grep -q "lastSavePath\" value=\"/tmp\"" "$XDG_CONFIG_HOME/xournalpp/settings.xml"'
expect "Xournal++: notes about a vault file deleted" '[ ! -e "$XDG_CACHE_HOME/xournalpp/metadata/1.metadata" ]'

echo "test-vault: one part failing leaves the others running"
echo "not xml" > "$lo/registrymodifications.xcu"
printf '[General]\nfiledialog-path=%s\n' "$M" > "$vlc/vlc-qt-interface.conf"
v check > "$T/check2.txt"
expect "a broken LibreOffice file is reported as failed" 'grep -q "FAILED   LibreOffice" "$T/check2.txt"'
expect "and VLC is still cleaned in the same run" '! grep -q filedialog-path "$vlc/vlc-qt-interface.conf"'
expect "the broken part raises its own warning" 'grep -q "LibreOffice.s history could not be switched off or cleaned" "$W/warnings.txt"'
rm "$lo/registrymodifications.xcu"

echo "test-vault: an app's files wait until it closes"
cp /usr/bin/sleep "$T/bin/vlc"; "$T/bin/vlc" 300 & fakevlc=$!
printf '[General]\nfiledialog-path=%s\n' "$M" > "$vlc/vlc-qt-interface.conf"
v check > "$T/check3.txt"
expect "VLC open: its files are left alone and it says so" 'grep -q "later    VLC" "$T/check3.txt" && grep -q filedialog-path "$vlc/vlc-qt-interface.conf"'
expect "once LibreOffice works again its warning goes" '! grep -q LibreOffice "$W/warnings.txt"'
expect "and the notification is replaced with one saying it is fixed" 'grep -q -- "-r 42 Vault: fixed LibreOffice is working again" "$T/notified"'
kill "$fakevlc"; wait "$fakevlc" 2>/dev/null
v check > /dev/null
expect "VLC closed: the next check cleans it" '! grep -q filedialog-path "$vlc/vlc-qt-interface.conf"'

echo "test-vault: locking"
bash -c "trap '' TERM HUP; cd '$M'; while :; do sleep 1; done" & stubborn=$!
cp /usr/bin/sleep "$T/bin/dummyviewer"; "$T/bin/dummyviewer" 300 & viewer=$!
sleep 300 & control=$!
sleep 0.3
v close > "$T/close.txt"
expect "vault close locks it" '! mounted'
expect "a program that ignores SIGTERM in the vault is still closed" '! alive $stubborn'
expect "an app that put a vault file in Recent is closed" '! alive $viewer'
expect "an unrelated program is left running" 'alive $control'
expect "the locked mount point is read-only" '[ "$(stat -c %a "$M")" = 500 ]'
expect "thumbnails are back to their default" '[ -z "$(thumbs)" ]'
expect "nothing is left to restore" '[ ! -e "$HOME/.local/state/vault/paused-settings.json" ]'
kill "$control"

echo "test-vault: with the vault locked, the check still clears leftovers"
mkdir -p "$XDG_DATA_HOME/org.gnome.TextEditor"
recent "$XDG_DATA_HOME/org.gnome.TextEditor/recently-used.xbel" "file://$M/later.txt" gnome-text-editor
recent "$XDG_DATA_HOME/recently-used.xbel" "file://$HOME/Vault/photo.jpg" dummyviewer
v check --quiet
expect "Text Editor's own recent list is cleaned" '! grep -q later.txt "$XDG_DATA_HOME/org.gnome.TextEditor/recently-used.xbel"'
expect "GNOME's Recent list is cleaned" '! grep -q photo.jpg "$XDG_DATA_HOME/recently-used.xbel"'
expect "nothing is remembered to close while locked" '[ ! -e "$VAULT_STATE/apps.json" ]'

echo "test-vault: a sleep the guard never saw"
open_vault
py -c "import json; p='$VAULT_STATE/opened.json'; d=json.load(open(p)); d['sleep'] -= 600; json.dump(d, open(p, 'w'))"
v check --quiet
expect "the check locks a vault that slept while open" '! mounted'
expect "and raises a critical warning about it" 'grep -q -- "-u critical.*the guard missed a lock.*slept while it was open" "$T/notified"'
expect "which waits until it has been seen" 'grep -q missed-lock "$W/warnings.json"'
v check > "$T/check4.txt"
expect "vault check shows it" 'grep -q "the guard missed a lock" "$T/check4.txt"'
expect "and then clears it" '! grep -q missed-lock "$W/warnings.json"'

echo "test-vault: gocryptfs dies under an open vault"
open_vault
pkill -9 -f "gocryptfs.*$HOME/.vault"; sleep 0.5
v check --quiet
expect "the dead mount is cleared" '! grep -q " $M " /proc/self/mountinfo'
expect "the mount point is read-only again" '[ "$(stat -c %a "$M")" = 500 ]'
expect "thumbnails are restored" '[ -z "$(thumbs)" ]'

echo "test-vault: a crash between pausing thumbnails and mounting"
mkdir -p "$HOME/.local/state/vault"; echo '{"/org/gnome/desktop/thumbnailers/disable-all": ""}' > "$HOME/.local/state/vault/paused-settings.json"
dconf write /org/gnome/desktop/thumbnailers/disable-all true
v check --quiet
expect "the check puts thumbnails back on" '[ -z "$(thumbs)" ] && [ ! -e "$HOME/.local/state/vault/paused-settings.json" ]'

echo "test-vault: when the check itself cannot run"
PATH="$T/bin:$PATH" bash "$repo/modules/vault-alarm.sh" vault-check.service
expect "the shell alarm raises a critical notification" 'grep -q -- "-u critical.*2-minute check failed to run" "$T/notified"'
PATH="$T/bin:$PATH" bash "$repo/modules/vault-alarm.sh" vault-check.service
expect "and does not repeat it on the next failure" '[ "$(grep -c "2-minute check failed to run" "$T/notified")" -eq 1 ]'
expect "new terminals show it" 'bash "$repo/modules/vault-banner.sh" | grep -q "⚠ Vault: the 2-minute check failed to run"'
v check --quiet
expect "the next check that runs clears it" '[ ! -e "$W/alarms.txt" ]'
expect "a terminal with nothing to report shows nothing" '[ -z "$(XDG_STATE_HOME="$T/none" bash "$repo/modules/vault-banner.sh")" ]'

echo "test-vault: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
