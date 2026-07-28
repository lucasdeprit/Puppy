#!/usr/bin/env bash
set -euo pipefail

# usage.sh [--pct]
#
# Reports Claude Pro subscription usage (5-hour session window and 7-day
# weekly window) by shelling out to `claude -p "/usage"`. This is the
# claude.ai subscription rate limit, unrelated to API/Console token billing.
#
# --pct prints a compact machine-readable line ("<5h>|<7d>", empty fields if
# unavailable) for other scripts (e.g. `puppy ls`'s header) to consume.
# With no args, prints a human-readable report with a bar per window plus
# the "what's contributing to your limits" breakdown from Claude Code itself.

# Color only when writing to a real terminal (not piped into a file/other
# script), so 'puppy usage --pct' and redirected output stay plain text.
if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi

color_for() {
  # $1 = percentage -> color code by severity threshold
  local pct_int
  pct_int=$(printf '%.0f' "$1" 2>/dev/null || echo 0)
  if (( pct_int >= 80 )); then echo "$RED"
  elif (( pct_int >= 50 )); then echo "$YELLOW"
  else echo "$GREEN"
  fi
}

bar() {
  # $1 = percentage, $2 = bar width in cells. Solid unicode blocks (█ filled,
  # ░ empty), colored by severity — filled portion in its threshold color,
  # empty portion dim, matching Claude Code's own /statusline preview style.
  local pct="$1" width="$2"
  local pct_int filled empty out i color
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null || echo 0)
  filled=$(( pct_int * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( width - filled ))
  color=$(color_for "$pct")
  out="${color}"
  for ((i=0; i<filled; i++)); do out="${out}█"; done
  out="${out}${RESET}${DIM}"
  for ((i=0; i<empty; i++)); do out="${out}░"; done
  echo "${out}${RESET}"
}

time_left() {
  # $1 = reset string as printed by `/usage`, e.g. "Jul 28 at 12:20pm (Europe/Madrid)"
  # Prints "Xh Ym" until reset, or nothing if it can't be parsed (e.g. non-macOS
  # date, unexpected format) — callers should treat that as "unavailable".
  local reset_str="$1" tz clean year epoch now diff
  tz=$(echo "$reset_str" | sed -n 's/.*(\(.*\))/\1/p')
  clean=$(echo "$reset_str" | sed -E 's/ \([^)]*\)$//')
  [[ -z "$tz" || -z "$clean" ]] && return 1
  # On-the-hour resets print without minutes (e.g. "1am" instead of
  # "1:00am") — normalize so the fixed-format parse below always matches.
  if [[ ! "$clean" =~ : ]]; then
    clean=$(echo "$clean" | sed -E 's/([0-9]+)(am|pm)$/\1:00\2/')
  fi
  year=$(date +%Y)
  epoch=$(TZ="$tz" date -j -f "%b %d at %I:%M%p %Y" "$clean $year" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  diff=$(( epoch - now ))
  # If the parsed date already passed this year (e.g. reset is in January but
  # today is December), it actually falls next year.
  if (( diff < -86400 )); then
    epoch=$(TZ="$tz" date -j -f "%b %d at %I:%M%p %Y" "$clean $((year + 1))" +%s 2>/dev/null) || return 1
    diff=$(( epoch - now ))
  fi
  (( diff < 0 )) && diff=0
  echo "$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
}

result=$(claude -p "/usage" --output-format json 2>/dev/null | jq -r '.result // empty')

five_pct=$(echo "$result" | sed -n 's/^Current session: \([0-9]*\)% used.*/\1/p')
five_reset=$(echo "$result" | sed -n 's/^Current session: [0-9]*% used · resets \(.*\)/\1/p')
week_pct=$(echo "$result" | sed -n 's/^Current week[^:]*: \([0-9]*\)% used.*/\1/p')
week_reset=$(echo "$result" | sed -n 's/^Current week[^:]*: [0-9]*% used · resets \(.*\)/\1/p')

five_left=""
week_left=""
[[ -n "$five_reset" ]] && five_left=$(time_left "$five_reset" || true)
[[ -n "$week_reset" ]] && week_left=$(time_left "$week_reset" || true)

if [[ "${1:-}" == "--pct" ]]; then
  echo "${five_pct}|${week_pct}|${five_left}|${week_left}"
  exit 0
fi

if [[ -z "$five_pct" && -z "$week_pct" ]]; then
  echo "No se pudo obtener el uso de la suscripción (¿claude no está disponible?)." >&2
  exit 1
fi

if [[ -n "$five_pct" ]]; then
  echo "5h  [$(bar "$five_pct" 20)] $(color_for "$five_pct")${five_pct}%${RESET} (resets ${five_reset}${five_left:+ · in $five_left})"
fi
if [[ -n "$week_pct" ]]; then
  echo "7d  [$(bar "$week_pct" 20)] $(color_for "$week_pct")${week_pct}%${RESET} (resets ${week_reset}${week_left:+ · in $week_left})"
fi

breakdown=$(echo "$result" | sed -n '/What.s contributing/,$p')
if [[ -n "$breakdown" ]]; then
  echo
  echo "$breakdown"
fi
