#!/usr/bin/env bash
set -euo pipefail

# spawn-pup.sh <pup-id> <repo-path> <branch> <prompt...>
#
# Creates an isolated worktree for <repo-path>, starts a Claude worker inside
# it, sends it the prompt, and launches watch-pup.sh in the background to
# notify puppy when it finishes. Non-blocking.

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

# Before creating the worktree, check whether the target branch is already
# in use. If a worktree already has that branch checked out, abort with a
# clear message instead of letting 'herdr worktree create' (or the
# underlying git) fail with a raw error.
existing_wt_path=$(git -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree / { path=$2 }
  /^branch / { if ($2 == b) print path }
')
if [[ -n "$existing_wt_path" ]]; then
  echo "error: la rama '$branch' ya está checked out en $existing_wt_path" >&2
  exit 1
fi

# If the branch exists but isn't in any worktree (e.g. left over from a
# previous attempt whose worktree was already deleted), let it pass instead
# of aborting: it's a legitimate case and 'herdr worktree create' will reuse
# it as a base instead of creating a new branch. We just warn so it's on
# record in the pup log that we're not starting from a fresh branch.
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "aviso: la rama '$branch' ya existe (sin worktree activo); se reutilizará" >&2
fi

create_json=$(herdr worktree create --cwd "$repo" --branch "$branch" --no-focus --json)
if echo "$create_json" | jq -e '.error' >/dev/null 2>&1; then
  echo "error creando worktree: $(echo "$create_json" | jq -r '.error.message')" >&2
  exit 1
fi

pane=$(echo "$create_json" | jq -r '.result.root_pane.pane_id')
workspace=$(echo "$create_json" | jq -r '.result.workspace.workspace_id')
worktree_path=$(echo "$create_json" | jq -r '.result.worktree.path')

# If the target repo brings its own knowledge/memory infrastructure (by
# convention, not specific to any project), we tell the worker about it in
# the prompt itself instead of touching the real repo.
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

# The newly created pane may take a moment to be ready.
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

# The pane may report "idle" and interactive_ready=true before the Claude
# Code UI has finished rendering and is really accepting keystrokes: sending
# the prompt immediately can silently get lost. We use --wait --until
# working to confirm the prompt actually triggered the worker, and retry if
# not.
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
