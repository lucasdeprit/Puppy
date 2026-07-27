#!/usr/bin/env bash
set -euo pipefail

# spawn-pup.sh <pup-id> <repo-path> <branch> <prompt...>
#
# Crea un worktree aislado para <repo-path>, arranca un worker Claude dentro,
# le manda el prompt, y lanza watch-pup.sh en background para avisar al
# puppy cuando termine. No bloquea.

if [[ $# -lt 4 ]]; then
  echo "uso: spawn-pup.sh <pup-id> <repo-path> <branch> <prompt...>" >&2
  exit 1
fi

task_id=$1; repo=$2; branch=$3; shift 3
prompt="$*"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
puppy_dir="$(dirname "$script_dir")"
tasks_dir="$puppy_dir/data/tasks"
events_log="$puppy_dir/data/events.log"
task_file="$tasks_dir/$task_id.json"

mkdir -p "$tasks_dir"

if [[ -e "$task_file" ]]; then
  echo "error: ya existe un pup con id '$task_id' ($task_file)" >&2
  exit 1
fi

repo="$(cd "$repo" && pwd)"
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: '$repo' no es un repo git" >&2
  exit 1
fi

puppy_pane="${HERDR_PANE_ID:-}"
if [[ -z "$puppy_pane" ]]; then
  echo "error: HERDR_PANE_ID no está definido; este script debe correr dentro de una sesión herdr" >&2
  exit 1
fi

create_json=$(herdr worktree create --cwd "$repo" --branch "$branch" --no-focus --json)
if echo "$create_json" | jq -e '.error' >/dev/null 2>&1; then
  echo "error creando worktree: $(echo "$create_json" | jq -r '.error.message')" >&2
  exit 1
fi

pane=$(echo "$create_json" | jq -r '.result.root_pane.pane_id')
workspace=$(echo "$create_json" | jq -r '.result.workspace.workspace_id')
worktree_path=$(echo "$create_json" | jq -r '.result.worktree.path')

# Si el repo destino trae su propia infraestructura de conocimiento/memoria
# (por convención, no específico de ningún proyecto), se lo indicamos al
# worker en el propio prompt en vez de tocar el repo real.
context_preamble=""
if [[ -f "$worktree_path/open-knowledge/map.md" ]]; then
  context_preamble+="Antes de nada, lee open-knowledge/map.md en la raíz de este repo: contiene las reglas no negociables y el enrutador de tareas de este proyecto. Sigue esas reglas y consulta solo los documentos que ese mapa te indique para tu tarea concreta.

"
fi
if [[ -f "$worktree_path/.engram/config.json" ]]; then
  context_preamble+="Este repo usa Engram para memoria persistente entre sesiones. Antes de empezar, ejecuta 'engram search <tema relevante>' para ver si hay contexto de sesiones anteriores. Al terminar cambios significativos, ejecuta 'engram save <título> <resumen>' con lo aprendido o decidido (nunca guardes secretos, tokens ni credenciales).

"
fi
full_prompt="${context_preamble}${prompt}"

# El pane recién creado puede tardar un instante en estar listo.
started=0
for attempt in 1 2 3 4 5; do
  if herdr agent start "$task_id" --kind claude --pane "$pane" -- --permission-mode acceptEdits >/dev/null 2>&1; then
    started=1
    break
  fi
  sleep 1
done
if [[ "$started" -ne 1 ]]; then
  echo "error: no se pudo arrancar el worker en el pane $pane" >&2
  exit 1
fi

# El pane puede reportarse "idle" e interactive_ready=true antes de que la UI
# de Claude Code haya terminado de renderizar y esté realmente aceptando
# teclas: un envío inmediato del prompt se puede perder en silencio. Usamos
# --wait --until working para confirmar que el prompt realmente disparó al
# worker, y reintentamos si no.
prompted=0
for attempt in 1 2 3 4 5; do
  if herdr agent prompt "$pane" "$full_prompt" --wait --until working --timeout 5000 >/dev/null 2>&1; then
    prompted=1
    break
  fi
  sleep 1
done
if [[ "$prompted" -ne 1 ]]; then
  echo "error: el prompt no llegó a arrancar al worker en el pane $pane tras varios intentos" >&2
  exit 1
fi

created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n \
  --arg task_id "$task_id" \
  --arg repo "$repo" \
  --arg branch "$branch" \
  --arg worktree_path "$worktree_path" \
  --arg workspace "$workspace" \
  --arg pane "$pane" \
  --arg puppy_pane "$puppy_pane" \
  --arg created_at "$created_at" \
  --arg prompt "$prompt" \
  --arg context_preamble "$context_preamble" \
  '{task_id: $task_id, repo: $repo, branch: $branch, worktree_path: $worktree_path,
    workspace_id: $workspace, pane_id: $pane, puppy_pane_id: $puppy_pane,
    status: "started", created_at: $created_at, prompt: $prompt,
    context_preamble: $context_preamble}' \
  > "$task_file"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $task_id started pane=$pane worktree=$worktree_path" >> "$events_log"

nohup "$script_dir/watch-pup.sh" "$task_id" >/dev/null 2>&1 &
watcher_pid=$!
disown

tmp_file=$(mktemp)
jq --arg watcher_pid "$watcher_pid" '.watcher_pid = ($watcher_pid | tonumber)' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"

echo "Pup '$task_id' lanzado. worktree=$worktree_path pane=$pane watcher_pid=$watcher_pid"
