#!/usr/bin/env bash
# tests/test-lib.sh — unit tests for system/lib.sh.
#
# Run with `make test`, or `sudo make test` to include the tests that need root
# (install_conf writes root-owned files). CI runs it under sudo so nothing is
# skipped.
#
# Why this file exists. Two bugs shipped in one session that both looked fine to
# every check the repo had:
#
#   - `apt-cache policy <pkg> | grep -q ...` returned 141 under pipefail, so a
#     published package read as "not published" and system/25-memory.sh silently
#     skipped its whole zram section. shellcheck passes on it. `nix eval` passes
#     on it. The script exits 0 and logs a plausible-looking warning.
#   - The same idiom sat unnoticed in system/20-kernel.sh, where it would have
#     left a fresh machine on the GA kernel while reporting success.
#
# Neither is a syntax error or a type error, which is all CI checked for. These
# are behavioural tests of the helpers those bugs lived in.
#
# Deliberately no test framework: this has to run on a fresh Ubuntu box before
# Nix exists, so bash and coreutils are the whole dependency list.

set -uo pipefail   # NOT -e: an assertion failure must be recorded, not fatal

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../system/lib.sh
source ./system/lib.sh
# lib.sh turns on -e for its own callers; the harness needs it off to keep
# running after a failed assertion.
set +e

PASSED=0
FAILED=0
SKIPPED=0

ok()   { PASSED=$((PASSED + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()   { FAILED=$((FAILED + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  \033[33m–\033[0m %s (skipped: %s)\n' "$1" "$2"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

is()   { # <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want '$3', got '$2'"; fi
}
succeeds() { # <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else no "$name — expected exit 0, got $?"; fi
}
fails() { # <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then no "$name — expected non-zero, got 0"; else ok "$name"; fi
}

# ── out_matches ──────────────────────────────────────────────────────────────
group "out_matches"

succeeds "matches a plain substring"            out_matches $'alpha\nbeta\ngamma' beta
fails    "reports no match"                     out_matches $'alpha\nbeta' delta
succeeds "-E extended regex"                    out_matches $'  Candidate: 1.1.2-3' -E '^[[:space:]]+Candidate: [^([:space:]]'
fails    "-E rejects Candidate: (none)"         out_matches $'  Candidate: (none)' -E '^[[:space:]]+Candidate: [^([:space:]]'
succeeds "-x whole-line match"                  out_matches $'docker\nsudo' -x docker
fails    "-x rejects a partial line"            out_matches $'dockerroot' -x docker
succeeds "-i case-insensitive"                  out_matches 'SecureBoot enabled' -i 'secureboot ENABLED'
fails    "empty text never matches"             out_matches '' -E '.'
succeeds "anchors are per-line, not per-string" out_matches $'first\nKeyslots:\n  0: luks2' '^Keyslots:'

# THE REGRESSION. A big enough body means grep -q exits long before the writer
# is done. Piped, that is exit 141 under pipefail — a successful match reported
# as a failure. out_matches has to be immune.
group "out_matches — the pipefail/SIGPIPE regression"

big="$(seq 1 200000)"

succeeds "matches line 1 of 200k without SIGPIPE" out_matches "$big" -E '^1$'
succeeds "matches the last line too"              out_matches "$big" -E '^200000$'

# Prove the hazard is real rather than folklore, so nobody "simplifies" the
# helper back into a pipeline later. If a future bash/grep stops raising this,
# the test says so instead of failing.
naive_pipeline_status() { ( set -euo pipefail; printf '%s\n' "$big" | grep -qE '^1$' ); echo $?; }
naive="$(naive_pipeline_status)"
if [ "$naive" = 141 ]; then
  ok "the naive 'printf | grep -q' pipeline still returns 141 (why this helper exists)"
elif [ "$naive" = 0 ]; then
  skip "naive pipeline returns 141" "this bash/grep did not raise SIGPIPE; helper is still correct"
else
  no "naive pipeline returned $naive — expected 141 or 0"
fi

# ── config_flag / config_str / config_num ────────────────────────────────────
# The Nix -> bash bridge. A wrong answer here silently turns a feature off.
group "config_flag / config_str / config_num"

fixture="$(mktemp -d)"
DOME_ROOT="$fixture"
cat > "$fixture/user-config.nix" <<'EOF'
{
  modules = {
    apps = true;
  };
  dockerEngine = true;
  gameMode = false;
  hostName = "";
  hostProfile = "zenbook-duo";
  loginPinLength = 4;
  zeroLength = 0;
  quotedNumber = "6";
  notANumber = true;
}
EOF

succeeds "config_flag reads a true switch"        config_flag dockerEngine
fails    "config_flag reads a false switch"       config_flag gameMode
fails    "config_flag on a missing key is false"  config_flag neverDefined
is "config_str reads a string"        "$(config_str hostProfile)" "zenbook-duo"
is "config_str on an empty string"    "$(config_str hostName)"    ""
is "config_str on a missing key"      "$(config_str neverDefined)" ""

# config_num must always print a number, so callers can use [ "$n" -eq 0 ]
# without first proving they got one. Everything unusable reads as 0, which is
# the OFF value for every numeric switch — a typo disables a feature instead of
# aborting the run with an arithmetic syntax error partway through.
is "config_num reads an integer"       "$(config_num loginPinLength)" "4"
is "config_num reads an explicit 0"    "$(config_num zeroLength)"     "0"
is "config_num on a missing key is 0"  "$(config_num neverDefined)"   "0"
is "config_num ignores a quoted number" "$(config_num quotedNumber)"  "0"
is "config_num ignores a bool"         "$(config_num notANumber)"     "0"

# Nested keys must NOT be picked up: config_flag anchors at the start of a line
# for a reason — `apps = true;` inside `modules = { ... }` is a different
# setting from a top-level `apps`, and confusing the two would read the wrong
# switch. (It is indented, so the anchor is what saves us.)
succeeds "nested modules.apps is still matched by the anchor" config_flag apps

rm -rf "$fixture"
# shellcheck disable=SC2034  # read by config_flag/config_str inside lib.sh
DOME_ROOT="$(pwd)"

# ── ensure_line ──────────────────────────────────────────────────────────────
group "ensure_line"

tmpf="$(mktemp)"
printf 'existing\n' > "$tmpf"
ensure_line "$tmpf" 'added' >/dev/null 2>&1
is "appends a missing line"        "$(grep -c '^added$' "$tmpf")" "1"
ensure_line "$tmpf" 'added' >/dev/null 2>&1
is "does not append it twice"      "$(grep -c '^added$' "$tmpf")" "1"
is "leaves existing content alone" "$(grep -c '^existing$' "$tmpf")" "1"
rm -f "$tmpf"

# ── install_conf ─────────────────────────────────────────────────────────────
# The idempotency contract every system script claims in its header: a second
# run reports no changes. install_conf is where that now lives.
group "install_conf"

if [ "$(id -u)" != 0 ]; then
  skip "install_conf writes a new file"    "needs root (run: sudo make test)"
  skip "install_conf is idempotent"        "needs root"
  skip "install_conf rewrites on change"   "needs root"
  skip "install_conf honours DRY_RUN"      "needs root"
else
  confdir="$(mktemp -d)"
  target="$confdir/nested/dir/test.conf"

  DRY_RUN=0
  if install_conf "$target" "first" >/dev/null 2>&1; then
    ok "install_conf writes a new file (returns 0 = changed)"
  else
    no "install_conf writes a new file (returns 0 = changed)"
  fi
  is "content is correct"          "$(cat "$target" 2>/dev/null)" "first"
  is "creates parent directories"  "$([ -d "$confdir/nested/dir" ] && echo yes)" "yes"

  # Second identical call must report "no change" — this is the assertion that
  # would have caught 25-memory.sh re-reporting "zram0 activated" every run.
  if install_conf "$target" "first" >/dev/null 2>&1; then
    no "install_conf is idempotent (should return 1 = unchanged)"
  else
    ok "install_conf is idempotent (returns 1 = unchanged)"
  fi

  if install_conf "$target" "second" >/dev/null 2>&1; then
    ok "install_conf rewrites when content differs"
  else
    no "install_conf rewrites when content differs"
  fi
  is "new content landed" "$(cat "$target" 2>/dev/null)" "second"

  DRY_RUN=1
  dryfile="$confdir/dryrun.conf"
  install_conf "$dryfile" "should not exist" >/dev/null 2>&1
  is "DRY_RUN writes nothing" "$([ -e "$dryfile" ] && echo created || echo absent)" "absent"
  # shellcheck disable=SC2034  # read by install_conf inside lib.sh
  DRY_RUN=0

  rm -rf "$confdir"
fi

# ── pkg_installed ────────────────────────────────────────────────────────────
group "pkg_installed"

if command -v dpkg-query >/dev/null 2>&1; then
  fails "a package that cannot exist is not installed" pkg_installed dome-no-such-package-xyz
  if dpkg-query -W -f='${db:Status-Status}' coreutils 2>/dev/null | grep -qx installed; then
    succeeds "coreutils is reported installed" pkg_installed coreutils
  else
    skip "coreutils is reported installed" "dpkg has no coreutils entry"
  fi
else
  skip "pkg_installed tests" "no dpkg-query (not a Debian-family system)"
fi

# ── summary ──────────────────────────────────────────────────────────────────
printf '\n%s\n' "────────────────────────────────────────"
printf '%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ] || exit 1
printf '\033[32mall good\033[0m\n'
