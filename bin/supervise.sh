#!/usr/bin/env bash
set -uo pipefail

# supervise.sh [--all] [pup-id ...]
#
# Blocks until one of the given tasks (or all tasks still in "started"
# state, if no ids are passed) changes state.
#
# By default, both the auto-discovery of "started" pups (no ids given) and
# the ids themselves are scoped to the active project's data; --all (in any
# position among the arguments) switches both to every project (see
# puppy_data_dirs_for_scope / puppy_find_task in lib/project.sh).
#
# NOTE: doesn't use bash's `wait -n` on background jobs because Claude
# Code's Bash tool doesn't persist shell state (nor the job table) between
# calls — each invocation can run in a different shell process.
# watch-pup.sh already proactively notifies via `herdr agent prompt` as
# soon as a task resolves; this script is only for the case where the
# user asks to wait synchronously, and it does so by polling every
# scoped project's tasks/*.json.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

all=""
ids=()
for arg in "$@"; do
  case "$arg" in
    --all) all="--all" ;;
    *) ids+=("$arg") ;;
  esac
done

if [[ ${#ids[@]} -eq 0 ]]; then
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    while IFS= read -r f; do
      id=$(basename "$f" .json)
      status=$(jq -r '.status' "$f")
      [[ "$status" == "started" ]] && ids+=("$id")
    done < <(find "$d/tasks" -maxdepth 1 -name '*.json' 2>/dev/null)
  done < <(puppy_data_dirs_for_scope "$all")
else
  # Validate every explicitly given id up front: the polling loop below
  # silently skips (and therefore hangs forever on) an id that doesn't
  # resolve, which is now much more likely to happen by accident with the
  # scoped-by-default lookup.
  for id in "${ids[@]}"; do
    puppy_find_task "$id" "$all" >/dev/null || exit 1
  done
fi

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "No hay tareas en estado 'started' que esperar."
  exit 0
fi

echo "Esperando a que resuelva alguno de estos pups: ${ids[*]}"
while true; do
  for id in "${ids[@]}"; do
    f=$(puppy_find_task "$id" "$all" 2>/dev/null) || continue
    status=$(jq -r '.status' "$f")
    if [[ "$status" != "started" ]]; then
      echo "El pup '$id' resolvió con estado: $status"
      exit 0
    fi
  done
  sleep 2
done
