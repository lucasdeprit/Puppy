#!/usr/bin/env bash
set -uo pipefail

# forget-project.sh [project-dir] [--force]
#
# Stops Puppy's session for the given project (same as `puppy stop`) and then
# completely erases its saved data (~/.local/share/puppy/projects/<slug>/):
# tasks, events.log, the recorded project path, everything. Doesn't touch any
# pup's actual worktree or branch.
#
# Same warn-then-require-confirmation pattern as remove-pup.sh: if any pup
# registered under this project isn't done/merged yet, forgetting the project
# also forgets that pup's metadata (worktree path, PR info, etc.), so this
# asks for confirmation (y/n on a tty) or requires --force otherwise.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

force=0
project_arg=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) project_arg="$arg" ;;
  esac
done

project_dir="$(cd "${project_arg:-$PWD}" && pwd -P)"
slug=$(puppy_project_slug "$project_dir")
label="puppy-$slug"
project_root="$HOME/.local/share/puppy/projects/$slug"
data_dir="$project_root/data"

if [[ ! -d "$project_root" ]]; then
  echo "No hay datos guardados de Puppy para $project_dir; nada que olvidar."
  exit 0
fi

pending=()
if [[ -d "$data_dir/tasks" ]]; then
  for f in "$data_dir/tasks"/*.json; do
    [[ -e "$f" ]] || continue
    status=$(jq -r '.status // "desconocido"' "$f")
    case "$status" in
      done|merged) ;;
      *) pending+=("$(basename "$f" .json) (estado: $status)") ;;
    esac
  done
fi

if [[ ${#pending[@]} -gt 0 ]]; then
  echo "AVISO: hay pups sin terminar (ni done ni merged) en $project_dir:" >&2
  printf '  %s\n' "${pending[@]}" >&2
  echo "Olvidar el proyecto borra su metadata (no sus worktrees ni ramas)." >&2
  if [[ "$force" -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
      read -r -p "¿Seguro que quieres olvidar este proyecto igualmente? [y/N]: " answer
      case "$answer" in
        y|Y|yes|si|sí|s) ;;
        *) echo "Cancelado."; exit 1 ;;
      esac
    else
      echo "Usa --force si de verdad quieres olvidar el proyecto de todos modos." >&2
      exit 1
    fi
  fi
fi

# Stop the session first, exactly like `puppy stop`.
"$script_dir/puppy" stop "$project_dir"

rm -rf "$project_root"
echo "Proyecto $project_dir olvidado: borrados sus datos guardados ($project_root)."
