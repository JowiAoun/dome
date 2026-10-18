# shellcheck shell=bash
# Auto-activate a project's Python virtualenv on entering it, and drop it again
# on leaving. Sourced by both bash and zsh (home.nix), which each call
# `_venv_auto` whenever the directory changes.
#
# Walks up from $PWD so a shell sitting in src/ or tests/ still finds the venv
# at the project root, and stops below $HOME so a stray ~/.venv never leaks
# into every unrelated directory. Only folders inside $HOME are searched, so a
# venv someone else left in /tmp is never picked up.
#
# Activating a venv runs its bin/activate, which is a shell script. A repo you
# just cloned or an archive you just unpacked could ship one, so a venv is only
# activated when it was made here:
#   - it is on the trusted list (`venv-trust` adds it), or
#   - it sits in a git checkout and git does not track it. `git clone` only
#     writes tracked files, so an untracked venv was made after the clone,
#     by you or your tools (uv sync, python -m venv).
# Anything else prints a one-line hint and is left alone.
#
# Only a venv this hook activated is ever deactivated: $_VENV_AUTO records
# which one that was. A venv sourced by hand, or one that pyenv-virtualenv
# switched on from a .python-version file, is left strictly alone. In zsh,
# pyenv registers its own chpwd hook earlier and runs first, so we see its
# $VIRTUAL_ENV and stand down.

_VENV_AUTO_TRUST="${XDG_STATE_HOME:-$HOME/.local/state}/venv-auto/trusted"

_venv_auto_find() {
  _VENV_AUTO_FOUND=""
  local d=$PWD name
  case $d in "$HOME"/*) ;; *) return ;; esac
  while [ -n "$d" ] && [ "$d" != "$HOME" ]; do
    for name in .venv venv; do
      if [ -f "$d/$name/bin/activate" ]; then
        _VENV_AUTO_FOUND="$d/$name"
        return
      fi
    done
    d=${d%/*}
  done
}

# Whether the venv at $1 was made on this machine (see the top of this file).
_venv_auto_trusted() {
  local real
  real=$(cd -P -- "$1" 2>/dev/null && pwd) || return 1
  if [ -f "$_VENV_AUTO_TRUST" ] && grep -Fxq -- "$real" "$_VENV_AUTO_TRUST"; then
    return 0
  fi
  # fsmonitor is a program named in .git/config. An unpacked archive can ship
  # its own .git, so never let this check start one.
  git -C "$real" -c core.fsmonitor=false rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    ! git -C "$real" -c core.fsmonitor=false ls-files --error-unmatch -- bin/activate >/dev/null 2>&1
}

_venv_auto() {
  _venv_auto_find
  # Someone else owns the live venv -> hands off.
  if [ -n "${VIRTUAL_ENV:-}" ] && [ "$VIRTUAL_ENV" != "${_VENV_AUTO:-}" ]; then return; fi
  if [ "$_VENV_AUTO_FOUND" = "${VIRTUAL_ENV:-}" ]; then return; fi
  if [ -n "$_VENV_AUTO_FOUND" ] && ! _venv_auto_trusted "$_VENV_AUTO_FOUND"; then
    # Once per venv per shell, so moving around inside the project stays quiet.
    if [ "$_VENV_AUTO_FOUND" != "${_VENV_AUTO_HINTED:-}" ]; then
      # shellcheck disable=SC2016  # the backticks are text for you to read
      printf 'venv: %s is not trusted yet, so it was not activated. If you made it, run `venv-trust`.\n' \
        "$_VENV_AUTO_FOUND" >&2
      _VENV_AUTO_HINTED=$_VENV_AUTO_FOUND
    fi
    _VENV_AUTO_FOUND=""
  fi
  if [ -n "${VIRTUAL_ENV:-}" ]; then
    deactivate 2>/dev/null
    _VENV_AUTO=""
  fi
  if [ -n "$_VENV_AUTO_FOUND" ]; then
    . "$_VENV_AUTO_FOUND/bin/activate"
    _VENV_AUTO="$_VENV_AUTO_FOUND"
  fi
}

# Trust the venv for the current folder, and activate it.
venv-trust() {
  local real
  _venv_auto_find
  if [ -z "$_VENV_AUTO_FOUND" ]; then
    echo "venv-trust: no .venv or venv here or in a folder above it (inside your home folder)" >&2
    return 1
  fi
  real=$(cd -P -- "$_VENV_AUTO_FOUND" && pwd) || return 1
  mkdir -p -- "${_VENV_AUTO_TRUST%/*}"
  if ! { [ -f "$_VENV_AUTO_TRUST" ] && grep -Fxq -- "$real" "$_VENV_AUTO_TRUST"; }; then
    printf '%s\n' "$real" >> "$_VENV_AUTO_TRUST"
  fi
  echo "venv-trust: $real is trusted"
  _venv_auto
}
