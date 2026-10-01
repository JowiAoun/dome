#!/usr/bin/env bash
# Turn a GNOME shortcut into an OBS action, so recording and scene keys work
# when OBS is not the focused window. modules/obs.nix explains why that is
# needed and binds the keys; this is the command they run.
#
# Arguments go straight to obs-cmd, so `obs-hotkey recording toggle` works and
# so does every other verb it has (`obs-cmd --help` lists them).
#
# The one exception is `scene-key`, which takes a key the way OBS spells it:
#
#   obs-hotkey scene-key control+shift+OBS_KEY_EXCLAM
#
# That looks up whichever scene OBS has bound to that key in the collection it
# currently has open, and switches to it. The point is that the scene's NAME is
# never written down outside OBS, so renaming or reordering scenes cannot break
# the shortcut. obs-cmd can only switch scenes by name, which is why this is
# resolved here instead.
#
# The port and password come from the file obs-websocket writes for itself, so
# there is exactly one copy of them and OBS owns it. Neither is stored in this
# repo or in the Nix store.
set -euo pipefail

obsdir="${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio"
conf="$obsdir/plugin_config/obs-websocket/config.json"

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

args=("$@")

if [ "$1" = scene-key ]; then
  [ "$#" -eq 2 ] || die "scene-key takes one key spec, such as control+shift+OBS_KEY_EXCLAM"

  want_key=""
  want_control=false
  want_shift=false
  want_alt=false
  want_command=false
  IFS='+' read -r -a parts <<< "$2"
  for part in "${parts[@]}"; do
    case "$part" in
      control | ctrl)  want_control=true ;;
      shift)           want_shift=true ;;
      alt)             want_alt=true ;;
      command | super) want_command=true ;;
      OBS_KEY_*)       want_key="$part" ;;
      *)               die "unknown piece '$part' in key spec '$2'" ;;
    esac
  done
  [ -n "$want_key" ] || die "key spec '$2' names no OBS_KEY_* key"

  # Which collection is open. OBS moved this setting from global.ini to
  # user.ini, so the newer file is tried first.
  ini="$obsdir/user.ini"
  [ -f "$ini" ] || ini="$obsdir/global.ini"
  collection="$(sed -nE 's/^SceneCollectionFile=(.+)$/\1/p' "$ini" | head -n1)"
  [ -n "$collection" ] || die "cannot tell which scene collection OBS has open"

  json="$obsdir/basic/scenes/$collection"
  [ -f "$json" ] || die "scene collection $collection is missing"

  # Scenes are sources with id "scene", and each carries its own
  # OBSBasic.SelectScene binding. any/1 over the array, because any(gen; cond)
  # would hand the whole array to the condition instead of its elements.
  scene="$(jq -r --arg k "$want_key" \
    --argjson c "$want_control" --argjson s "$want_shift" \
    --argjson a "$want_alt" --argjson m "$want_command" '
      [ .sources[]
        | select(.id == "scene")
        | select((.hotkeys["OBSBasic.SelectScene"] // [])
            | any(.key == $k
                  and (.control // false) == $c
                  and (.shift   // false) == $s
                  and (.alt     // false) == $a
                  and (.command // false) == $m))
        | .name ] | first // empty' "$json")"
  [ -n "$scene" ] || die "OBS has no scene bound to $2"

  args=(scene switch "$scene")
fi

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
if ! out="$(obs-cmd --websocket "obsws://localhost:$port/$pass" "${args[@]}" 2>&1)"; then
  die "$(printf '%s' "$out" | tail -n1)"
fi
