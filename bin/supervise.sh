#!/usr/bin/env bash
set -uo pipefail

# supervise.sh [pup-id ...]
#
# Blocks until one of the given tasks (or all tasks still in "started"
# state, if no arguments are passed) changes state.
#
# NOTE: doesn't use bash's `wait -n` on background jobs because Claude
# Code's Bash tool doesn't persist shell state (nor the job table) between
# calls — each invocation can run in a different shell process.
# watch-pup.sh already proactively notifies via `herdr agent prompt` as
# soon as a task resolves; this script is only for the case where the
# user asks to wait synchronously, and it does so by polling every
# project's tasks/*.json (see lib/project.sh).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

ids=("$@")
if [[ ${#ids[@]} -eq 0 ]]; then
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    while IFS= read -r f; do
      id=$(basename "$f" .json)
      status=$(jq -r '.status' "$f")
      [[ "$status" == "started" ]] && ids+=("$id")
    done < <(find "$d/tasks" -maxdepth 1 -name '*.json' 2>/dev/null)
  done < <(puppy_all_data_dirs)
fi

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "No hay tareas en estado 'started' que esperar."
  exit 0
fi

echo "Esperando a que resuelva alguno de estos pups: ${ids[*]}"
while true; do
  for id in "${ids[@]}"; do
    f=$(puppy_find_task "$id" 2>/dev/null) || continue
    status=$(jq -r '.status' "$f")
    if [[ "$status" != "started" ]]; then
      echo "El pup '$id' resolvió con estado: $status"
      exit 0
    fi
  done
  sleep 2
done
