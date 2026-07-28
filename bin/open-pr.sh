#!/usr/bin/env bash
set -euo pipefail

# open-pr.sh <pup-id> [-- <extra gh pr create args>]
#
# Pushea la rama de la tarea y abre un PR con `gh pr create`. No fusiona
# nada directamente: el flujo por defecto es PR, no merge directo. Guarda
# la URL del PR en data/tasks/<pup-id>.json.

if [[ $# -lt 1 ]]; then
  echo "uso: open-pr.sh <pup-id> [-- <extra gh pr create args>]" >&2
  exit 1
fi

task_id=$1; shift
if [[ "${1:-}" == "--" ]]; then shift; fi
extra_args=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
puppy_dir="$(dirname "$script_dir")"
task_file="$puppy_dir/data/tasks/$task_id.json"

if [[ ! -f "$task_file" ]]; then
  echo "error: no existe $task_file" >&2
  exit 1
fi

worktree_path=$(jq -r '.worktree_path' "$task_file")
branch=$(jq -r '.branch' "$task_file")

if [[ ! -d "$worktree_path" ]]; then
  echo "error: el worktree '$worktree_path' ya no existe" >&2
  exit 1
fi

dirty=$(git -C "$worktree_path" status --porcelain)
if [[ -n "$dirty" ]]; then
  echo "AVISO: hay cambios sin commitear en '$worktree_path', no abro PR:" >&2
  echo "$dirty" >&2
  exit 1
fi

git -C "$worktree_path" push -u origin "$branch"

pr_url=$(cd "$worktree_path" && gh pr create --fill "${extra_args[@]}" 2>&1 | tail -1)

pr_json=$(cd "$worktree_path" && gh pr view "$branch" --json url,number,state 2>/dev/null || echo '{}')
pr_number=$(echo "$pr_json" | jq -r '.number // empty')
pr_state=$(echo "$pr_json" | jq -r '.state // "OPEN"')
pr_url=$(echo "$pr_json" | jq -r --arg fallback "$pr_url" '.url // $fallback')

tmp_file=$(mktemp)
jq --arg pr_url "$pr_url" --arg pr_number "$pr_number" --arg pr_state "$pr_state" \
  '.pr_url = $pr_url | .pr = {url: $pr_url, number: ($pr_number | if . == "" then null else tonumber end), state: $pr_state}' \
  "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"

echo "PR abierto para '$task_id': $pr_url"
