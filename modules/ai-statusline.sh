#!/usr/bin/env bash
# Claude Code status line.
#
# Left (shell-like) part mirrors ~/.config/starship.toml as closely as a
# status line can:
#   [username]   style_user = "bold dimmed green", show_always = true
#   [directory]  style = "bold cyan", home_symbol = "~", truncation_length = 3,
#                truncation_symbol = "…/", truncate_to_repo = false
#   [git_branch] style = "bold purple"; the glyph itself is read live from
#                starship.toml so it always matches the shell prompt exactly
#                (it's a Nerd Font codepoint, not something safe to retype
#                by hand). Falls back to no glyph if the toml can't be read
#                or doesn't set one.
#
# Right part is Claude-specific, all from the documented status line JSON
# contract on stdin: model, context window remaining %, and the subscription
# rate limits (.rate_limits.five_hour / .seven_day).
#
# Rate limits are shown as REMAINING rather than the used_percentage the
# contract provides, since what you want to know is how much budget is left,
# and with the time until the window resets in parentheses — a countdown is
# what actually decides "keep going now or wait", where a wall-clock time
# would need mental arithmetic.
#
# There is no per-model rate limit in the contract: the schema has exactly two
# windows, five_hour and seven_day, both across all models. Per-model usage
# (Fable, Opus, …) is visible in /usage but is not passed to status lines, so
# it cannot be shown here.
#
# The two kinds of percentage read in opposite directions on purpose:
#
#   ctx   how much of the context window is USED — it climbs as the session
#         fills up, which is the way you think about a window you are filling
#   5h/7d how much of the rate limit window is LEFT — a budget you spend down
#
# What keeps that legible is that the colour always means the same thing: it is
# computed from the consumed share either way, so green/yellow/red degrade
# together and red is bad everywhere. Context goes yellow at 60% consumed and
# red at 80%; the rate limits are more forgiving (50%/80%) since they refill on
# their own and a full window is a wait, not a loss.
#
# Output is two rows — the status line renders one row per line printed — so
# the shell-like identity and the Claude session state stop competing for
# horizontal space:
#
#   <user> <dir> <branch?>
#   <model> · <ctx%> · 5h <n>% (<eta>) · 7d <n>% (<eta>)
#
# Any segment whose source data is missing is dropped cleanly (no stray
# separators/symbols), and an entirely empty row is not printed at all rather
# than showing up as a blank line. rate_limits in particular is absent for
# non-Claude.ai-subscription usage and until the first API response of a
# session, and each window can go missing independently.

input=$(cat)

# Single jq call: pull everything we need out of the JSON at once.
#
# Separated by US (), NOT by tab. Tab is an IFS *whitespace* character,
# so bash collapses runs of them into one delimiter and strips leading ones —
# which silently shifts every later field left as soon as one is empty. That is
# not hypothetical: with no context_window in the payload, the 5-hour usage
# landed in $remaining and got rendered as the context percentage. US is not
# IFS whitespace, so empty fields survive as empty fields.
IFS=$'\x1f' read -r model cwd ctx_used five_used five_reset seven_used seven_reset <<< "$(
  printf '%s' "$input" | jq -r '
    def num(v): if v == null then "" else (v | tostring) end;
    [
      (.model.display_name // ""),
      (.workspace.current_dir // .cwd // ""),
      num(.context_window.used_percentage //
          (if .context_window.remaining_percentage == null then null
           else 100 - .context_window.remaining_percentage end)),
      num(.rate_limits.five_hour.used_percentage),
      num(.rate_limits.five_hour.resets_at),
      num(.rate_limits.seven_day.used_percentage),
      num(.rate_limits.seven_day.resets_at)
    ] | join("")'
)"

RESET=$'\033[0m'
USER_STYLE=$'\033[1;2;32m'   # bold dimmed green (starship username.style_user)
DIR_STYLE=$'\033[1;36m'      # bold cyan          (starship directory.style)
GIT_STYLE=$'\033[1;35m'      # bold purple        (starship git_branch.style)
DIM=$'\033[2m'               # reset countdowns — present but not competing
OK_STYLE=$'\033[32m'         # >50% of the window left
WARN_STYLE=$'\033[33m'       # 20-50% left
CRIT_STYLE=$'\033[31m'       # <20% left

join_by() {
  local sep="$1"; shift
  local out="" first=1 part
  for part in "$@"; do
    [[ -z "$part" ]] && continue
    if (( first )); then out="$part"; first=0; else out="${out}${sep}${part}"; fi
  done
  printf '%s' "$out"
}

# ---- username segment ("@ jowi"), starship [username] ----
user="${USER:-$(whoami)}"
user_seg=$(printf '%s@ %s%s' "$USER_STYLE" "$user" "$RESET")

# ---- directory segment, starship [directory] ----
# ~ for $HOME, keep at most the last 3 path components, "…/" prefix when
# truncated (truncate_to_repo = false, so this ignores repo boundaries).
dir_display() {
  local p="$1" home="${HOME:-}" display root rest joined
  if [[ -n "$home" && "$p" == "$home" ]]; then
    display="~"
  elif [[ -n "$home" && "$p" == "$home"/* ]]; then
    display="~${p#"$home"}"
  else
    display="$p"
  fi

  root=""; rest="$display"
  if [[ "$display" == "~"* ]]; then
    root="~"
    rest="${display#\~}"
    rest="${rest#/}"
  elif [[ "$display" == "/"* ]]; then
    root="/"
    rest="${display#/}"
  fi

  if [[ -z "$rest" ]]; then
    printf '%s' "$display"
    return
  fi

  local parts=()
  local IFS='/'
  read -ra parts <<< "$rest"
  local n=${#parts[@]}
  if (( n > 3 )); then
    local last3=("${parts[@]: -3}")
    joined=$(IFS='/'; printf '%s' "${last3[*]}")
    printf '…/%s' "$joined"
  else
    joined=$(IFS='/'; printf '%s' "${parts[*]}")
    case "$root" in
      "~") printf '~/%s' "$joined" ;;
      "/") printf '/%s' "$joined" ;;
      *) printf '%s' "$joined" ;;
    esac
  fi
}

dir_seg=""
if [[ -n "$cwd" ]]; then
  dir_raw=$(dir_display "$cwd")
  dir_seg=$(printf '%s%s%s' "$DIR_STYLE" "$dir_raw" "$RESET")
fi

# ---- git branch segment, starship [git_branch] ----
git_seg=""
if [[ -n "$cwd" ]] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
  if [[ -z "$branch" ]] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Detached HEAD but still a repo: fall back to a short SHA.
    branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
  if [[ -n "$branch" ]]; then
    symbol=""
    toml="$HOME/.config/starship.toml"
    if [[ -r "$toml" ]]; then
      symbol=$(awk '
        /^\[git_branch\]/ { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $0 ~ /^[[:space:]]*symbol[[:space:]]*=/ {
          line=$0
          sub(/^[^"]*"/, "", line)
          sub(/".*$/, "", line)
          print line
          exit
        }
      ' "$toml" 2>/dev/null)
    fi
    git_seg=$(printf '%s%s%s%s' "$GIT_STYLE" "$symbol" "$branch" "$RESET")
  fi
fi

shell_block=$(join_by ' ' "$user_seg" "$dir_seg" "$git_seg")

# Colour by severity. Thresholds are always expressed on the CONSUMED share,
# whichever way round the number beside them is displayed — so the colour means
# the same thing everywhere on the line even though ctx counts up and the rate
# limit windows count down.
#
#   style_for <used%> <warn at or above> <crit at or above>
style_for() {
  local used="$1" warn="$2" crit="$3"
  if   (( used >= crit )); then printf '%s' "$CRIT_STYLE"
  elif (( used >= warn )); then printf '%s' "$WARN_STYLE"
  else                          printf '%s' "$OK_STYLE"
  fi
}

# ---- Claude segments: model + context used ----
claude_segments=()
[[ -n "$model" ]] && claude_segments+=("$model")
if [[ -n "$ctx_used" ]]; then
  pct=$(printf '%.0f' "$ctx_used" 2>/dev/null)
  if [[ -n "$pct" ]]; then
    claude_segments+=("$(printf '%s%s%%%s ctx' "$(style_for "$pct" 60 80)" "$pct" "$RESET")")
  fi
fi

# ---- rate limit segments (Claude.ai subscription windows) ----
# Seconds until reset, as a compact countdown: "3d4h", "2h14m", "9m".
fmt_eta() {
  local secs="$1" d h m
  (( secs <= 0 )) && { printf 'due'; return; }
  d=$(( secs / 86400 )); h=$(( secs % 86400 / 3600 )); m=$(( secs % 3600 / 60 ))
  if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  else                   printf '%dm' "$m"
  fi
}

# "5h 77% (2h14m)" — label, remaining %, countdown to the window reset.
limit_seg() {
  local label="$1" used="$2" reset_at="$3" left style eta=""
  [[ -z "$used" ]] && return                       # window absent: emit nothing
  left=$(awk -v u="$used" 'BEGIN { v = 100 - u; if (v < 0) v = 0; printf "%.0f", v }')
  style=$(style_for $(( 100 - left )) 50 80)   # yellow at half spent, red at four fifths
  if [[ -n "$reset_at" ]]; then
    eta=$(printf '%s (%s)%s' "$DIM" "$(fmt_eta $(( ${reset_at%%.*} - $(date +%s) )))" "$RESET")
  fi
  printf '%s %s%s%%%s%s' "$label" "$style" "$left" "$RESET" "$eta"
}

five_seg=$(limit_seg '5h' "$five_used" "$five_reset")
seven_seg=$(limit_seg '7d' "$seven_used" "$seven_reset")
[[ -n "$five_seg"  ]] && claude_segments+=("$five_seg")
[[ -n "$seven_seg" ]] && claude_segments+=("$seven_seg")

claude_block=$(join_by ' · ' "${claude_segments[@]}")

if [[ -n "$shell_block" ]]; then
  printf '%s\n' "$shell_block"
fi
if [[ -n "$claude_block" ]]; then
  printf '%s\n' "$claude_block"
fi

# Never let an empty final test decide the script's exit status.
exit 0
