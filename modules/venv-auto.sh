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
# Activating a venv runs its bin/activate, which is a shell script, and puts
# its bin/ first on PATH. A repo you cloned or an archive you unpacked could
# ship a venv, and nothing in the folder shows who made it: an archive can even
# bring its own .git. So only a venv on your trusted list is activated. A venv
# goes on the list when:
#   - you run `venv-trust` in it, or
#   - in zsh, `uv`, `virtualenv` or `python -m venv` makes it for the folder
#     you ran the command in (home.nix runs `_venv_auto_before` and
#     `_venv_auto_after` around each command).
# The list names each venv folder by its inode and creation time, so a venv
# that is deleted and replaced by another at the same path is not trusted.
# Any other venv prints a one-line hint and is left alone.
#
# A trusted venv is still refused while git tracks any file in it. Git ignores
# a venv (the venv writes its own .gitignore), and git replaces ignored files
# without asking. So a pull, or a pull request you check out, could swap the
# files in a venv you made for ones from the commit. This does not catch an
# archive unpacked on top of your project, which can replace them the same way.
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

# How the trusted list names a venv folder: its inode and creation time.
_venv_auto_id() {
  command stat -L -c '%i:%.9W' -- "$1" 2>/dev/null
}

# Each line of the list is an id, a space, and the path, which is only there
# for you to read.
_venv_auto_trusted() {
  local id line
  id=$(_venv_auto_id "$1") && [ -n "$id" ] && [ -f "$_VENV_AUTO_TRUST" ] || return 1
  while IFS= read -r line; do
    [ "${line%% *}" = "$id" ] && return 0
  done < "$_VENV_AUTO_TRUST"
  return 1
}

_venv_auto_trust() {
  local id
  _venv_auto_trusted "$1" && return 0
  id=$(_venv_auto_id "$1") && [ -n "$id" ] || return 1
  mkdir -p -- "${_VENV_AUTO_TRUST%/*}"
  printf '%s %s\n' "$id" "${1//$'\n'/?}" >> "$_VENV_AUTO_TRUST"
}

# Whether git tracks any file in the venv at $1.
_venv_auto_tracked() {
  # fsmonitor is a program named in .git/config, so never let this start one.
  [ -n "$(git -C "$1" -c core.fsmonitor=false ls-files -- . 2>/dev/null)" ]
}

_venv_auto() {
  local why=""
  _venv_auto_find
  # Someone else owns the live venv -> hands off.
  if [ -n "${VIRTUAL_ENV:-}" ] && [ "$VIRTUAL_ENV" != "${_VENV_AUTO:-}" ]; then return; fi
  if [ "$_VENV_AUTO_FOUND" = "${VIRTUAL_ENV:-}" ]; then return; fi
  if [ -z "$_VENV_AUTO_FOUND" ]; then
    :
  elif ! _venv_auto_trusted "$_VENV_AUTO_FOUND"; then
    # shellcheck disable=SC2016  # the backticks are text for you to read
    why='is not trusted yet, so it was not activated. If you made it, run `venv-trust`.'
  elif _venv_auto_tracked "$_VENV_AUTO_FOUND"; then
    why='has files that git tracks, so it was not activated. A commit put them there, so check them before you use it.'
  fi
  if [ -n "$why" ]; then
    # Once per venv per shell, so moving around inside the project stays quiet.
    if [ "$_VENV_AUTO_FOUND" != "${_VENV_AUTO_HINTED:-}" ]; then
      printf 'venv: %s %s\n' "$_VENV_AUTO_FOUND" "$why" >&2
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

# Run before each command you type, with that command. Only the venv tools are
# watched: a venv that shows up while `tar` or `unzip` runs is not yours to
# trust. Notes every .venv or venv folder the search could find, with or
# without a bin/activate yet.
_venv_auto_before() {
  local cmd flag module rest d=$PWD name
  _VENV_AUTO_CMD_PWD=""
  read -r cmd flag module rest <<< "$1"
  case $cmd in
    uv | virtualenv) ;;
    python | python3 | python3.*)
      [ "$flag" = -m ] && { [ "$module" = venv ] || [ "$module" = virtualenv ]; } || return 0 ;;
    *) return 0 ;;
  esac
  case $d in "$HOME"/*) ;; *) return 0 ;; esac
  _VENV_AUTO_CMD_IDS=" "
  while [ -n "$d" ] && [ "$d" != "$HOME" ]; do
    for name in .venv venv; do
      if [ -d "$d/$name" ]; then _VENV_AUTO_CMD_IDS+="$(_venv_auto_id "$d/$name") "; fi
    done
    d=${d%/*}
  done
  _VENV_AUTO_CMD_PWD=$PWD
}

# Run after it. A venv folder that did not exist before the command was made
# by it, so it is trusted and activated. A folder that was already there is
# not, even if the command filled it in: an archive could have left programs
# in its bin/. Keeps $? as the command left it, for the prompt to show.
_venv_auto_after() {
  local ret=$? id
  if [ -n "${_VENV_AUTO_CMD_PWD:-}" ] && [ "$_VENV_AUTO_CMD_PWD" = "$PWD" ]; then
    _venv_auto_find
    if [ -n "$_VENV_AUTO_FOUND" ] && id=$(_venv_auto_id "$_VENV_AUTO_FOUND") && [ -n "$id" ]; then
      case $_VENV_AUTO_CMD_IDS in
        *" $id "*) ;;
        *) _venv_auto_trust "$_VENV_AUTO_FOUND"; _venv_auto ;;
      esac
    fi
  fi
  _VENV_AUTO_CMD_PWD=""
  return "$ret"
}

# Trust the venv for the current folder, and activate it.
venv-trust() {
  _venv_auto_find
  if [ -z "$_VENV_AUTO_FOUND" ]; then
    echo "venv-trust: no .venv or venv here or in a folder above it (inside your home folder)" >&2
    return 1
  fi
  if ! _venv_auto_trust "$_VENV_AUTO_FOUND"; then
    echo "venv-trust: could not read $_VENV_AUTO_FOUND" >&2
    return 1
  fi
  echo "venv-trust: $_VENV_AUTO_FOUND is trusted"
  # Say again why it stays off, if it does.
  _VENV_AUTO_HINTED=""
  _venv_auto
}

# Run by home-manager (home.nix), not by your shell. With no list yet, it
# starts one from the venvs already in ~/p, so those keep activating. A list
# from before venvs were named by inode, one path per line, is rewritten.
_venv_auto_seed() {
  local line id venvs="" kept=""
  if [ -e "$_VENV_AUTO_TRUST" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        /*) venvs+=$line$'\n' ;;
        ?*) kept+=$line$'\n' ;;
      esac
    done < "$_VENV_AUTO_TRUST"
    [ -n "$venvs" ] || return 0
  else
    # find exits 1 on any folder it may not read.
    venvs=$(find "$HOME/p" -maxdepth 6 -name node_modules -prune -o -type f -name pyvenv.cfg -printf '%h\n' 2>/dev/null) || true
  fi
  while IFS= read -r line; do
    if [ -n "$line" ] && [ -f "$line/bin/activate" ] && id=$(_venv_auto_id "$line") && [ -n "$id" ]; then
      kept+="$id $line"$'\n'
    fi
  done <<< "$venvs"
  mkdir -p -- "${_VENV_AUTO_TRUST%/*}"
  printf '%s' "$kept" > "$_VENV_AUTO_TRUST.new" && mv -f -- "$_VENV_AUTO_TRUST.new" "$_VENV_AUTO_TRUST"
}
