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
list="$XDG_STATE_HOME/venv-auto/trusted"

# A venv whose activate leaves a mark, the way a planted one would run code.
make_venv() {
  mkdir -p "$1/bin"
  printf 'echo "$PWD" > "%s/ran"\nVIRTUAL_ENV="%s"\ndeactivate() { unset VIRTUAL_ENV; }\n' "$1" "$1" > "$1/bin/activate"
  : > "$1/pyvenv.cfg"
}
make_here() { make_venv "$PWD/.venv"; }
# Runs _venv_auto in a fresh shell sitting in $1, and prints what it activated.
enter() { (cd "$1" && . "$repo/modules/venv-auto.sh" && _venv_auto 2>"$T/hint" && printf '%s' "${VIRTUAL_ENV:-}"); }
# Types the command line $2 in $1 the way zsh runs it, with $3 doing what the
# command would do, and prints what was activated afterwards.
typed() { (cd "$1" && . "$repo/modules/venv-auto.sh" && _venv_auto_before "$2" && $3 && _venv_auto_after 2>"$T/hint" && printf '%s' "${VIRTUAL_ENV:-}"); }

echo "test-venv-auto: a venv you did not make"
mkdir -p "$HOME/unzipped" && git init -q "$HOME/unzipped"; make_venv "$HOME/unzipped/.venv"
expect "an archive that brings its own .git is not activated" '[ -z "$(enter "$HOME/unzipped")" ] && [ ! -e "$HOME/unzipped/.venv/ran" ]'
expect "and the shell says why, and how to trust it" 'grep -q "venv-trust" "$T/hint"'
git init -q "$HOME/cloned"; make_venv "$HOME/cloned/.venv"
git -C "$HOME/cloned" add .venv && git -C "$HOME/cloned" -c user.name=t -c user.email=t@t commit -qm venv
rm -f "$HOME/cloned/.venv/ran"
expect "a venv git tracks is not activated" '[ -z "$(enter "$HOME/cloned")" ] && [ ! -e "$HOME/cloned/.venv/ran" ]'
make_venv "$HOME/unpacked/.venv"
expect "a venv outside any git checkout is not activated" '[ -z "$(enter "$HOME/unpacked")" ] && [ ! -e "$HOME/unpacked/.venv/ran" ]'

echo "test-venv-auto: venv-trust"
(cd "$HOME/unpacked" && . "$repo/modules/venv-auto.sh" && venv-trust >/dev/null)
expect "puts it on the list" 'grep -q " $HOME/unpacked/.venv$" "$list"'
expect "and from then on it is activated" '[ "$(enter "$HOME/unpacked")" = "$HOME/unpacked/.venv" ]'
mkdir -p "$HOME/unpacked/src"
expect "and found from a folder below the project root" '[ "$(enter "$HOME/unpacked/src")" = "$HOME/unpacked/.venv" ]'
rm -r "$HOME/unpacked/.venv"; make_venv "$HOME/unpacked/.venv"
expect "a trusted venv deleted and replaced at the same path is not activated" '[ -z "$(enter "$HOME/unpacked")" ] && [ ! -e "$HOME/unpacked/.venv/ran" ]'

echo "test-venv-auto: a venv a tool makes for you (zsh)"
mkdir -p "$HOME/new"
expect "uv sync that makes a venv here: it is trusted and activated" '[ "$(typed "$HOME/new" "uv sync" make_here)" = "$HOME/new/.venv" ]'
mkdir -p "$HOME/new2"
expect "and the same for python3 -m venv" '[ "$(typed "$HOME/new2" "python3 -m venv .venv" make_here)" = "$HOME/new2/.venv" ]'
mkdir -p "$HOME/tarred"
expect "a venv that tar leaves here is not trusted" '[ -z "$(typed "$HOME/tarred" "tar xf project.tar" make_here)" ] && [ ! -e "$HOME/tarred/.venv/ran" ]'
expect "nor is it when you run uv there later" '[ -z "$(typed "$HOME/tarred" "uv sync" true)" ] && [ ! -e "$HOME/tarred/.venv/ran" ]'
expect "python3 running a script is not watched" '[ -z "$(cd "$HOME/new" && . "$repo/modules/venv-auto.sh" && _venv_auto_before "python3 app.py" && printf "%s" "$_VENV_AUTO_CMD_PWD")" ]'
mkdir -p "$HOME/moved"
expect "a venv in a folder the command moved to is not trusted" '[ -z "$(cd "$HOME/new" && . "$repo/modules/venv-auto.sh" && _venv_auto_before "uv sync" && cd "$HOME/moved" && make_here && _venv_auto_after 2>/dev/null && printf "%s" "${VIRTUAL_ENV:-}")" ]'
expect "the command's exit status is kept for the prompt" '(. "$repo/modules/venv-auto.sh"; (exit 3); _venv_auto_after; [ $? -eq 3 ])'

echo "test-venv-auto: the list from before"
rm -f "$list"; mkdir -p "$HOME/p/old"; make_venv "$HOME/p/old/.venv"
(. "$repo/modules/venv-auto.sh" && _venv_auto_seed)
expect "with no list, the venvs already in ~/p are trusted" '[ "$(enter "$HOME/p/old")" = "$HOME/p/old/.venv" ]'
printf '%s\n' "$HOME/unpacked/.venv" > "$list"
(. "$repo/modules/venv-auto.sh" && _venv_auto_seed)
expect "a list of bare paths is rewritten, and its venvs still activate" '! grep -q "^/" "$list" && [ "$(enter "$HOME/unpacked")" = "$HOME/unpacked/.venv" ]'

echo "test-venv-auto: folders outside your home folder"
make_venv "$T/shared/.venv"; mkdir -p "$T/shared/x"
expect "a venv in a shared folder such as /tmp is never looked at" '[ -z "$(enter "$T/shared/x")" ] && [ ! -e "$T/shared/.venv/ran" ] && [ ! -s "$T/hint" ]'

echo "test-venv-auto: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
