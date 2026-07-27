#!/usr/bin/env bash
set -uo pipefail

# supervise.sh [task-id ...]
#
# Bloquea hasta que alguna de las tareas indicadas (o todas las que sigan
# en estado "started" si no se pasan argumentos) cambie de estado.
#
# NOTA: no usa `wait -n` de bash sobre jobs en background porque el Bash
# tool de Claude Code no persiste el estado de shell (ni la tabla de jobs)
# entre llamadas — cada invocación puede correr en un proceso de shell
# distinto. watch-task.sh ya avisa de forma proactiva vía `herdr agent
# prompt` en cuanto una tarea resuelve; este script es solo para el caso
# en que el usuario pida esperar de forma síncrona, y lo hace sondeando
# data/tasks/*.json.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lead_dir="$(dirname "$script_dir")"
tasks_dir="$lead_dir/data/tasks"

ids=("$@")
if [[ ${#ids[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    id=$(basename "$f" .json)
    status=$(jq -r '.status' "$f")
    [[ "$status" == "started" ]] && ids+=("$id")
  done < <(find "$tasks_dir" -maxdepth 1 -name '*.json' 2>/dev/null)
fi

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "No hay tareas en estado 'started' que esperar."
  exit 0
fi

echo "Esperando a que alguna de estas tareas resuelva: ${ids[*]}"
while true; do
  for id in "${ids[@]}"; do
    f="$tasks_dir/$id.json"
    [[ -f "$f" ]] || continue
    status=$(jq -r '.status' "$f")
    if [[ "$status" != "started" ]]; then
      echo "Tarea '$id' resolvió con estado: $status"
      exit 0
    fi
  done
  sleep 2
done
