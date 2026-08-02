#!/usr/bin/env bash
set -uo pipefail

# remove-pup.sh <pup-id> [--force] [--all]
#
# Helps (doesn't hard-block) delete a task's worktree. Warns if there are
# uncommitted changes or unpushed commits; with --force deletes anyway.
# This is a helper, not a technical lock: nothing stops calling
# `herdr worktree remove` directly, the "don't delete without checking"
# rule lives in AGENTS.md.
#
# By default the pup is looked up only in the active project; --all searches
# every project (see puppy_find_task in lib/project.sh).

if [[ $# -lt 1 ]]; then
  echo "uso: remove-pup.sh <pup-id> [--force] [--all]" >&2
  exit 1
fi

task_id=$1; shift
force=0
all=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --all) all="--all" ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

task_file=$(puppy_find_task "$task_id" "$all") || exit 1

worktree_path=$(jq -r '.worktree_path' "$task_file")
workspace=$(jq -r '.workspace_id' "$task_file")
herdr_session=$(jq -r '.herdr_session // empty' "$task_file")
session_args=()
[[ -n "$herdr_session" ]] && session_args=(--session "$herdr_session")

if [[ ! -d "$worktree_path" ]]; then
  echo "aviso: el path '$worktree_path' ya no existe; borro solo el registro de la tarea."
else
  dirty=$(git -C "$worktree_path" status --porcelain)

  if [[ -n "$dirty" ]] && [[ "$force" -eq 0 ]]; then
    echo "AVISO: hay cambios sin commitear en '$worktree_path':" >&2
    echo "$dirty" >&2
    echo "Usa --force si de verdad quieres borrar de todos modos." >&2
    exit 1
  fi

  if git -C "$worktree_path" rev-parse '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$worktree_path" rev-list '@{u}..HEAD' | wc -l | tr -d ' ')
    if [[ "$ahead" != "0" ]] && [[ "$force" -eq 0 ]]; then
      echo "AVISO: hay $ahead commit(s) locales sin pushear en '$worktree_path'." >&2
      echo "Usa --force si de verdad quieres borrar de todos modos." >&2
      exit 1
    fi
  elif [[ "$force" -eq 0 ]]; then
    echo "AVISO: la rama no tiene upstream configurado, no puedo comprobar si está pusheada." >&2
    echo "Usa --force si de verdad quieres borrar de todos modos." >&2
    exit 1
  fi
fi

remove_json=$(herdr "${session_args[@]}" worktree remove --workspace "$workspace" --json)
if [[ $? -ne 0 ]] || echo "$remove_json" | jq -e '.error' >/dev/null 2>&1; then
  echo "error eliminando el worktree: $(echo "$remove_json" | jq -r '.error.message // "fallo desconocido"')" >&2
  echo "no se borró el registro de la tarea; podés reintentar o investigar." >&2
  exit 1
fi

rm -f "$task_file"
echo "Tarea '$task_id' y su worktree han sido eliminados."
