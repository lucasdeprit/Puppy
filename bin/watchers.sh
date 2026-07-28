#!/usr/bin/env bash
set -euo pipefail

# watchers.sh [--json]
#
# Lista los procesos watch-pup.sh en ejecución y detecta huérfanos en ambas
# direcciones:
#   1. Un watch-pup.sh corriendo cuyo pup-id ya no tiene
#      data/tasks/<id>.json (el pup fue borrado con 'puppy rm' pero el
#      watcher se quedó vivo).
#   2. Un pup con status "started" cuyo watcher_pid registrado ya no está
#      vivo (el watcher murió sin actualizar el estado del pup).
#
# Compatible con bash 3.2 (macOS): no usa arrays asociativos.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
puppy_dir="$(dirname "$script_dir")"
tasks_dir="$puppy_dir/data/tasks"

json_out=0
[[ "${1:-}" == "--json" ]] && json_out=1

is_alive() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null
}

# Cada línea: "<pid> <task_id>" para cada watch-pup.sh vivo.
running_list=$(pgrep -fl 'watch-pup\.sh' 2>/dev/null | awk '{print $1, $NF}' || true)

results=()

# Dirección 1: watcher corriendo sin task file.
if [[ -n "$running_list" ]]; then
  while IFS=' ' read -r pid tid; do
    [[ -z "$pid" ]] && continue
    task_file="$tasks_dir/$tid.json"
    if [[ ! -f "$task_file" ]]; then
      results+=("$(jq -n --arg pid "$pid" --arg task_id "$tid" --arg reason "no_task_file" \
        '{pid: ($pid|tonumber), task_id: $task_id, orphan: true, reason: $reason}')")
    fi
  done <<< "$running_list"
fi

# Dirección 2: pup "started" cuyo watcher_pid ya no está vivo.
if [[ -d "$tasks_dir" ]]; then
  for f in "$tasks_dir"/*.json; do
    [[ -e "$f" ]] || continue
    task_id=$(jq -r '.task_id' "$f")
    status=$(jq -r '.status' "$f")
    watcher_pid=$(jq -r '.watcher_pid // empty' "$f")
    [[ "$status" != "started" ]] && continue
    if [[ -z "$watcher_pid" ]]; then
      results+=("$(jq -n --arg task_id "$task_id" --arg reason "no_watcher_pid_recorded" \
        '{pid: null, task_id: $task_id, orphan: true, reason: $reason}')")
    elif ! is_alive "$watcher_pid"; then
      results+=("$(jq -n --arg pid "$watcher_pid" --arg task_id "$task_id" --arg reason "watcher_dead_pup_started" \
        '{pid: ($pid|tonumber), task_id: $task_id, orphan: true, reason: $reason}')")
    fi
  done
fi

if [[ $json_out -eq 1 ]]; then
  if [[ ${#results[@]} -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "${results[@]}" | jq -s '.'
  fi
  exit 0
fi

echo "Watchers activos (watch-pup.sh):"
if [[ -z "$running_list" ]]; then
  echo "  (ninguno)"
else
  while IFS=' ' read -r pid tid; do
    [[ -z "$pid" ]] && continue
    task_file="$tasks_dir/$tid.json"
    if [[ -f "$task_file" ]]; then
      echo "  pid=$pid pup=$tid"
    else
      echo "  pid=$pid pup=$tid  <-- HUÉRFANO (sin $task_file)"
    fi
  done <<< "$running_list"
fi

echo
echo "Pups 'started' sin watcher vivo:"
found_dead=0
if [[ -d "$tasks_dir" ]]; then
  for f in "$tasks_dir"/*.json; do
    [[ -e "$f" ]] || continue
    task_id=$(jq -r '.task_id' "$f")
    status=$(jq -r '.status' "$f")
    watcher_pid=$(jq -r '.watcher_pid // empty' "$f")
    [[ "$status" != "started" ]] && continue
    if [[ -z "$watcher_pid" ]]; then
      echo "  pup=$task_id  <-- sin watcher_pid registrado (pup lanzado antes de este cambio, o dato perdido)"
      found_dead=1
    elif ! is_alive "$watcher_pid"; then
      echo "  pup=$task_id watcher_pid=$watcher_pid  <-- MUERTO pero el pup sigue en 'started'"
      found_dead=1
    fi
  done
fi
[[ $found_dead -eq 0 ]] && echo "  (ninguno)"
