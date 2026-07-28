#!/usr/bin/env bash
set -euo pipefail

# watch-pup.sh <pup-id>
#
# Meant to run in the background (spawn-pup.sh launches it, and 'puppy
# tell' relaunches it after a follow-up). Blocks, waiting for pup <pup-id>
# to reach done/blocked/unknown/idle, logs the event, and notifies the
# main puppy by injecting a message into its own pane.

if [[ $# -lt 1 ]]; then
  echo "uso: watch-pup.sh <pup-id>" >&2
  exit 1
fi

task_id=$1
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

task_file=$(puppy_find_task "$task_id") || exit 1
data_dir="$(dirname "$(dirname "$task_file")")"
events_log="$data_dir/events.log"

pane=$(jq -r '.pane_id' "$task_file")
puppy_pane=$(jq -r '.puppy_pane_id' "$task_file")
repo=$(jq -r '.repo' "$task_file")
branch=$(jq -r '.branch' "$task_file")

result=$(herdr agent wait "$pane" --until done --until blocked --until unknown --until idle)
status=$(echo "$result" | jq -r '.result.agent.agent_status // "error"')

tmp_file=$(mktemp)
jq --arg status "$status" '.status = $status' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $task_id status=$status pane=$pane" >> "$events_log"

repo_name=$(basename "$repo")
herdr agent prompt "$puppy_pane" \
  "🐶 El pup '$task_id' ($repo_name#$branch) ha terminado con estado: $status. Revisa 'puppy status $task_id' y su events.log para más detalle." \
  >/dev/null 2>&1 || true
