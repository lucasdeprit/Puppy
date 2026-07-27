#!/usr/bin/env bash
set -euo pipefail

# watch-pup.sh <pup-id>
#
# Pensado para correr en background (lo lanza spawn-pup.sh). Espera,
# bloqueante, a que el pup <pup-id> llegue a done/blocked/unknown,
# registra el evento y avisa al puppy principal inyectando un mensaje en su propio pane.

if [[ $# -lt 1 ]]; then
  echo "uso: watch-pup.sh <pup-id>" >&2
  exit 1
fi

task_id=$1
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
puppy_dir="$(dirname "$script_dir")"
task_file="$puppy_dir/data/tasks/$task_id.json"
events_log="$puppy_dir/data/events.log"

if [[ ! -f "$task_file" ]]; then
  echo "error: no existe $task_file" >&2
  exit 1
fi

pane=$(jq -r '.pane_id' "$task_file")
puppy_pane=$(jq -r '.puppy_pane_id' "$task_file")
repo=$(jq -r '.repo' "$task_file")
branch=$(jq -r '.branch' "$task_file")

result=$(herdr agent wait "$pane" --until done --until blocked --until unknown)
status=$(echo "$result" | jq -r '.result.agent.agent_status // "error"')

tmp_file=$(mktemp)
jq --arg status "$status" '.status = $status' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $task_id status=$status pane=$pane" >> "$events_log"

repo_name=$(basename "$repo")
herdr agent prompt "$puppy_pane" \
  "🐶 El pup '$task_id' ($repo_name#$branch) ha terminado con estado: $status. Revisa data/tasks/$task_id.json y data/events.log para más detalle." \
  >/dev/null 2>&1 || true
