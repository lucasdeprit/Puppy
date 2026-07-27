#!/usr/bin/env bash
set -uo pipefail

# remove-worktree.sh <task-id> [--force]
#
# Ayuda (no bloquea de forma dura) a borrar el worktree de una tarea. Avisa
# si hay cambios sin commitear o commits sin pushear; con --force borra
# igualmente. Esto es un helper, no un candado técnico: nada impide llamar
# a `herdr worktree remove` directamente, la norma de "no borrar sin
# comprobar" vive en AGENTS.md.

if [[ $# -lt 1 ]]; then
  echo "uso: remove-worktree.sh <task-id> [--force]" >&2
  exit 1
fi

task_id=$1
force=0
[[ "${2:-}" == "--force" ]] && force=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lead_dir="$(dirname "$script_dir")"
task_file="$lead_dir/data/tasks/$task_id.json"

if [[ ! -f "$task_file" ]]; then
  echo "error: no existe $task_file" >&2
  exit 1
fi

worktree_path=$(jq -r '.worktree_path' "$task_file")
workspace=$(jq -r '.workspace_id' "$task_file")

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

herdr worktree remove --workspace "$workspace" --json
rm -f "$task_file"
echo "Tarea '$task_id' y su worktree han sido eliminados."
