#!/usr/bin/env bash
# Turn a GNOME shortcut into an OBS action, so recording keys work when OBS is
# not the focused window. modules/obs.nix explains why that is needed and binds
# the keys; this is the command they run.
#
# Arguments go straight to obs-cmd, so `obs-hotkey recording toggle` works and
# so does every other verb it has (`obs-cmd --help` lists them, and
# `trigger-hotkey <name>` fires any hotkey OBS itself defines).
#
# The port and password come from the file obs-websocket writes for itself, so
# there is exactly one copy of them and OBS owns it. Neither is stored in this
# repo or in the Nix store.
set -euo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugin_config/obs-websocket/config.json"

# One notification that replaces its predecessor instead of stacking, which is
# what the x-canonical-private-synchronous hint does in GNOME. A shortcut has no
# terminal, so without this a failure is completely silent.
note() {
  notify-send -a OBS -h string:x-canonical-private-synchronous:obs-hotkey "$@" || true
}

die() {
  note "OBS hotkey" "$1"
  echo "obs-hotkey: $1" >&2
  exit 1
}

[ "$#" -gt 0 ] || die "no action given, try: obs-hotkey recording toggle"
[ -f "$conf" ] || die "OBS has not written its WebSocket config yet. Start OBS once."

port="$(jq -r '.server_port // 4455' "$conf")"
pass="$(jq -r '.server_password // ""' "$conf")"

[ "$(jq -r '.server_enabled // false' "$conf")" = true ] \
  || die "the OBS WebSocket server is off: Tools > WebSocket Server Settings"

# obs-cmd retries twice, two seconds apart, before it reports a refused
# connection, so pressing a key with OBS closed would do nothing for four
# seconds and then complain about the wrong thing. One connect attempt answers
# that straight away and names what is actually wrong.
if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  die "OBS is not running"
fi

# Silence is success. There is deliberately no notification on the happy path:
# all obs-cmd has to say is "Result: Ok(true)", which tells you nothing and
# arrives once per keypress. A notification therefore always means something
# went wrong.
if ! out="$(obs-cmd --websocket "obsws://localhost:$port/$pass" "$@" 2>&1)"; then
  die "$(printf '%s' "$out" | tail -n1)"
fi
