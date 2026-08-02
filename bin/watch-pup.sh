#!/usr/bin/env bash
set -euo pipefail

# watch-pup.sh <pup-id> [data-dir]
#
# Meant to run in the background (spawn-pup.sh launches it, and 'puppy
# tell' relaunches it after a follow-up). Blocks, waiting for pup <pup-id>
# to reach done/blocked/unknown/idle, logs the event, and notifies the
# main puppy by injecting a message into its own pane.
#
# data-dir, if given, is the caller's already-resolved project data
# directory (spawn-pup.sh's own, or the one 'puppy tell' resolved via
# puppy_find_task, possibly with --all for a pup in another project) — used
# directly instead of re-resolving, since a re-lookup with the default
# active-project scope could fail to find a task that a --all lookup just
# found. With no data-dir (manual invocation), falls back to
# puppy_find_task with the default scope (the active project only).

if [[ $# -lt 1 ]]; then
  echo "uso: watch-pup.sh <pup-id> [data-dir]" >&2
  exit 1
fi

task_id=$1
data_dir="${2:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

if [[ -n "$data_dir" ]]; then
  task_file="$data_dir/tasks/$task_id.json"
  if [[ ! -f "$task_file" ]]; then
    echo "error: no se encontró '$task_file'" >&2
    exit 1
  fi
else
  task_file=$(puppy_find_task "$task_id") || exit 1
  data_dir="$(dirname "$(dirname "$task_file")")"
fi
events_log="$data_dir/events.log"

pane=$(jq -r '.pane_id' "$task_file")
puppy_pane=$(jq -r '.puppy_pane_id' "$task_file")
repo=$(jq -r '.repo' "$task_file")
branch=$(jq -r '.branch' "$task_file")
repo_name=$(basename "$repo")

# 'herdr agent wait' can fail on a transient hiccup (network, herdr itself)
# instead of ever resolving to one of the --until statuses. Retry a few
# times with a short backoff before giving up, same pattern as the
# start/prompt retries in spawn-pup.sh and bin/puppy.
result=""
wait_ok=0
for attempt in 1 2 3 4 5; do
  if result=$(herdr agent wait "$pane" --until done --until blocked --until unknown --until idle); then
    wait_ok=1
    break
  fi
  echo "aviso: 'herdr agent wait' falló para $task_id (intento $attempt/5)" >&2
  sleep "$attempt"
done

if [[ "$wait_ok" -ne 1 ]]; then
  # Don't touch task_file's status here: the pup itself may still be
  # running fine, it's the watcher that gave up. Overwriting status would
  # misrepresent the pup as done/blocked/etc. when we simply don't know.
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $task_id status=started watcher_error=wait_failed pane=$pane" >> "$events_log"
  herdr agent prompt "$puppy_pane" \
    "⚠️ El watcher del pup '$task_id' ($repo_name#$branch) falló tras varios intentos de 'herdr agent wait' y dejó de monitorearlo — el pup puede seguir corriendo, pero no hay forma automática de saber en qué estado quedó. Requiere revisión manual: revisá el pane $pane con 'puppy status $task_id' y considerá relanzar el watcher." \
    >/dev/null 2>&1 || true
  exit 1
fi

status=$(echo "$result" | jq -r '.result.agent.agent_status // "error"')

tmp_file=$(mktemp)
jq --arg status "$status" '.status = $status' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $task_id status=$status pane=$pane" >> "$events_log"

herdr agent prompt "$puppy_pane" \
  "🐶 El pup '$task_id' ($repo_name#$branch) ha terminado con estado: $status. Revisa 'puppy status $task_id' y su events.log para más detalle." \
  >/dev/null 2>&1 || true
