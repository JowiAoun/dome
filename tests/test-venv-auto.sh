#!/usr/bin/env bash
# Each check is a string that expect evals later, so it is single-quoted on purpose.
# shellcheck disable=SC2016
# Behavioural tests for modules/venv-auto.sh: which venvs a shell activates on
# its own when you cd into a folder. Plain bash, git and coreutils, in a
# throwaway $HOME.
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0
expect() {
  if eval "$2"; then pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

# A venv whose activate leaves a mark, the way a planted one would run code.
make_venv() {
  mkdir -p "$1/bin"
  printf 'echo "$PWD" > "%s/ran"\nVIRTUAL_ENV="%s"\ndeactivate() { unset VIRTUAL_ENV; }\n' "$1" "$1" > "$1/bin/activate"
  : > "$1/pyvenv.cfg"
}
# Runs _venv_auto in a fresh shell sitting in $1, and prints what it activated.
enter() { (cd "$1" && . "$repo/modules/venv-auto.sh" && _venv_auto 2>"$T/hint" && printf '%s' "${VIRTUAL_ENV:-}"); }

echo "test-venv-auto: a venv made after the clone"
git init -q "$HOME/made"; make_venv "$HOME/made/.venv"
expect "an untracked venv in a git checkout is activated" '[ "$(enter "$HOME/made")" = "$HOME/made/.venv" ]'
mkdir -p "$HOME/made/src"
expect "and found from a folder below the project root" '[ "$(enter "$HOME/made/src")" = "$HOME/made/.venv" ]'

echo "test-venv-auto: a venv that came with the repo"
git init -q "$HOME/cloned"; make_venv "$HOME/cloned/.venv"
git -C "$HOME/cloned" add .venv && git -C "$HOME/cloned" -c user.name=t -c user.email=t@t commit -qm venv
rm -f "$HOME/cloned/.venv/ran"
expect "a venv git tracks is not activated" '[ -z "$(enter "$HOME/cloned")" ] && [ ! -e "$HOME/cloned/.venv/ran" ]'
expect "and the shell says why, and how to trust it" 'grep -q "venv-trust" "$T/hint"'

echo "test-venv-auto: a venv outside any git checkout"
make_venv "$HOME/unpacked/.venv"
expect "is not activated" '[ -z "$(enter "$HOME/unpacked")" ] && [ ! -e "$HOME/unpacked/.venv/ran" ]'
(cd "$HOME/unpacked" && . "$repo/modules/venv-auto.sh" && venv-trust >/dev/null)
expect "venv-trust puts it on the list" 'grep -qx "$HOME/unpacked/.venv" "$XDG_STATE_HOME/venv-auto/trusted"'
expect "and from then on it is activated" '[ "$(enter "$HOME/unpacked")" = "$HOME/unpacked/.venv" ]'

echo "test-venv-auto: folders outside your home folder"
make_venv "$T/shared/.venv"; mkdir -p "$T/shared/x"
expect "a venv in a shared folder such as /tmp is never looked at" '[ -z "$(enter "$T/shared/x")" ] && [ ! -e "$T/shared/.venv/ran" ] && [ ! -s "$T/hint" ]'

echo "test-venv-auto: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
