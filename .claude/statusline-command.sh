#!/bin/bash
# Claude Code status line: shows Claude.ai subscription rate-limit usage
# (5-hour session window and 7-day weekly window), plus the current
# session's context-window usage. Each percentage/bar is colorized by
# severity threshold (green < 50%, yellow 50-79%, red >= 80%). The 5h/7d
# segments also show a compact countdown to their reset time, when
# available.
# Reads the statusLine JSON payload from stdin.

input=$(cat)

bar() {
  # $1 = percentage (integer or float), prints a 5-cell ascii bar
  local pct="$1"
  local pct_int
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null || echo 0)
  local filled=$(( pct_int / 20 ))
  [ "$filled" -gt 5 ] && filled=5
  [ "$filled" -lt 0 ] && filled=0
  local empty=$(( 5 - filled ))
  local out=""
  local i
  for ((i=0; i<filled; i++)); do out="${out}#"; done
  for ((i=0; i<empty; i++)); do out="${out}-"; done
  echo "$out"
}

five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Color codes: dim for the base line, plus a severity color per segment
# (works well on both light/dark themes as a subtle status line).
DIM=$'\033[2m'
RESET=$'\033[0m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

color_for() {
  # $1 = rounded integer percentage
  local pct_r="$1"
  if [ "$pct_r" -ge 80 ]; then
    echo "$RED"
  elif [ "$pct_r" -ge 50 ]; then
    echo "$YELLOW"
  else
    echo "$GREEN"
  fi
}

countdown() {
  # $1 = resets_at (epoch seconds), prints compact "Xh Ym" or "Xd Yh"
  # remaining, or nothing if input is missing/invalid/in the past.
  local resets_at="$1" now diff days hours mins
  [ -z "$resets_at" ] && return
  case "$resets_at" in
    ''|*[!0-9.]*) return ;;
  esac
  now=$(date +%s)
  resets_at=$(printf '%.0f' "$resets_at" 2>/dev/null) || return
  diff=$(( resets_at - now ))
  [ "$diff" -le 0 ] && return
  if [ "$diff" -ge 86400 ]; then
    days=$(( diff / 86400 ))
    hours=$(( (diff % 86400) / 3600 ))
    printf '%dd %dh' "$days" "$hours"
  else
    hours=$(( diff / 3600 ))
    mins=$(( (diff % 3600) / 60 ))
    printf '%dh %dm' "$hours" "$mins"
  fi
}

segment() {
  # $1 = label (e.g. "5h"), $2 = percentage (integer or float),
  # $3 = optional resets_at (epoch seconds) for a countdown suffix
  local label="$1" pct="$2" resets_at="$3" pct_r color cd
  pct_r=$(printf '%.0f' "$pct")
  color=$(color_for "$pct_r")
  printf '%s: %s%s%%%s%s [%s%s%s]' \
    "$label" "$color" "$pct_r" "$RESET" "$DIM" "$color" "$(bar "$pct")" "$RESET$DIM"
  if [ -n "$resets_at" ]; then
    cd=$(countdown "$resets_at")
    [ -n "$cd" ] && printf ' (%s)' "$cd"
  fi
}

if [ -z "$five" ] && [ -z "$week" ] && [ -z "$ctx" ]; then
  printf '%s5h: -- | 7d: --%s' "$DIM" "$RESET"
  exit 0
fi

segments=()
[ -n "$five" ] && segments+=("$(segment "5h" "$five" "$five_resets")")
[ -n "$week" ] && segments+=("$(segment "7d" "$week" "$week_resets")")
[ -n "$ctx" ] && segments+=("$(segment "ctx" "$ctx")")

if [ ${#segments[@]} -eq 0 ]; then
  printf '%s5h: -- | 7d: --%s' "$DIM" "$RESET"
  exit 0
fi

out=""
for s in "${segments[@]}"; do
  if [ -n "$out" ]; then
    out="${out}${DIM} | ${RESET}"
  fi
  out="${out}${s}"
done

printf '%s%s%s' "$DIM" "$out" "$RESET"
