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

bar() {
  # $1 = percentage, $2 = bar width in cells
  local pct="$1" width="$2"
  local pct_int filled empty out i
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null || echo 0)
  filled=$(( pct_int * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( width - filled ))
  out=""
  for ((i=0; i<filled; i++)); do out="${out}#"; done
  for ((i=0; i<empty; i++)); do out="${out}-"; done
  echo "$out"
}

result=$(claude -p "/usage" --output-format json 2>/dev/null | jq -r '.result // empty')

five_pct=$(echo "$result" | sed -n 's/^Current session: \([0-9]*\)% used.*/\1/p')
five_reset=$(echo "$result" | sed -n 's/^Current session: [0-9]*% used · resets \(.*\)/\1/p')
week_pct=$(echo "$result" | sed -n 's/^Current week[^:]*: \([0-9]*\)% used.*/\1/p')
week_reset=$(echo "$result" | sed -n 's/^Current week[^:]*: [0-9]*% used · resets \(.*\)/\1/p')

if [[ "${1:-}" == "--pct" ]]; then
  echo "${five_pct}|${week_pct}"
  exit 0
fi

if [[ -z "$five_pct" && -z "$week_pct" ]]; then
  echo "No se pudo obtener el uso de la suscripción (¿claude no está disponible?)." >&2
  exit 1
fi

if [[ -n "$five_pct" ]]; then
  echo "5h  [$(bar "$five_pct" 20)] ${five_pct}% (resets ${five_reset})"
fi
if [[ -n "$week_pct" ]]; then
  echo "7d  [$(bar "$week_pct" 20)] ${week_pct}% (resets ${week_reset})"
fi

breakdown=$(echo "$result" | sed -n '/What.s contributing/,$p')
if [[ -n "$breakdown" ]]; then
  echo
  echo "$breakdown"
fi
