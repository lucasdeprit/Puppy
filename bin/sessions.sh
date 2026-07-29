#!/usr/bin/env bash
set -euo pipefail

# sessions.sh — registry + herdr orchestration for named puppy main-agent
# sessions (data/sessions/<name>.json), one file per name. Not to be
# confused with pups/workers (data/tasks/<pup-id>.json), which are a
# separate namespace and untouched by this script.
#
# usage:
#   sessions.sh gen-uuid
#   sessions.sh list
#   sessions.sh start <name> [--fresh]
#   sessions.sh stop <name>
#   sessions.sh forget <name> [--force]
#
# Resume mechanism: never uses `claude --continue` (that resumes "most
# recent conversation in this directory", which is unreliable once
# anything else — e.g. bin/usage.sh's own `claude -p` calls — touches the
# same cwd). Instead every named session owns a stored session uuid,
# started with `--session-id` the first time and reattached with
# `--resume "$uuid"` every time after.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
puppy_dir="$(dirname "$script_dir")"
sessions_dir="$puppy_dir/data/sessions"

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Last-resort fallback (practically unreachable on any real machine
    # we run on): doesn't need to be RFC 4122-strict, just unique.
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
  fi
}

# One row per data/sessions/*.json, tab-separated:
#   name  session_id  open|closed  workspace_id  number  agent_status  last_started_at
# workspace_id/number/agent_status are empty for closed sessions. Sorted by
# last_started_at descending (most recent first) — shared by both `puppy
# ls` and the `puppy start` picker so the merge logic lives once.
list_sessions() {
  backfill_puppy_if_needed
  mkdir -p "$sessions_dir"
  local all_ws
  all_ws=$(herdr workspace list 2>/dev/null || echo '{}')
  local f name session_id last_started_at row
  shopt -s nullglob
  for f in "$sessions_dir"/*.json; do
    name=$(jq -r '.name' "$f")
    session_id=$(jq -r '.session_id' "$f")
    last_started_at=$(jq -r '.last_started_at' "$f")
    row=$(echo "$all_ws" | jq -rc --arg n "$name" '.result.workspaces[]? | select(.label==$n)' | head -1)
    if [[ -n "$row" ]]; then
      ws_id=$(echo "$row" | jq -r '.workspace_id')
      number=$(echo "$row" | jq -r '.number')
      agent_status=$(echo "$row" | jq -r '.agent_status // "unknown"')
      printf '%s\t%s\topen\t%s\t%s\t%s\t%s\n' "$name" "$session_id" "$ws_id" "$number" "$agent_status" "$last_started_at"
    else
      printf '%s\t%s\tclosed\t\t\t\t%s\n' "$name" "$session_id" "$last_started_at"
    fi
  done | sort -t $'\t' -k7,7 -r
  shopt -u nullglob
}

# Lazy, one-time migration (plan section 5): if a workspace labeled
# "puppy" is open (or has ever been started via the pre-redesign flow)
# but data/sessions/puppy.json doesn't exist yet, create the registry
# entry now with a fresh uuid. Doesn't touch any live pane — the new uuid
# only takes effect the next time that session is closed and restarted.
# There's no way to recover the old cwd-based --continue history
# retroactively, so this is a one-time, disclosed loss of continuity.
backfill_puppy_if_needed() {
  local reg_file="$sessions_dir/puppy.json"
  [[ -f "$reg_file" ]] && return 0
  mkdir -p "$sessions_dir"
  local uuid now
  uuid=$(gen_uuid)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n --arg name "puppy" --arg session_id "$uuid" --arg cwd "$puppy_dir" \
    --arg created_at "$now" --arg last_started_at "$now" \
    '{name: $name, session_id: $session_id, cwd: $cwd, created_at: $created_at, last_started_at: $last_started_at}' \
    > "$reg_file"
}

start_session() {
  local name="$1" fresh="${2:-0}"
  [[ "$name" == "puppy" ]] && backfill_puppy_if_needed
  mkdir -p "$sessions_dir"
  local reg_file="$sessions_dir/$name.json"

  local existing_ws
  existing_ws=$(herdr workspace list 2>/dev/null | jq -r --arg n "$name" '.result.workspaces[] | select(.label==$n) | .workspace_id' | head -1)

  if [[ -n "$existing_ws" && "$fresh" -eq 0 ]]; then
    # Backfill on the fly if this open workspace predates the registry
    # (same migration case as above, generalized to any name).
    if [[ ! -f "$reg_file" ]]; then
      local uuid now
      uuid=$(gen_uuid)
      now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      jq -n --arg name "$name" --arg session_id "$uuid" --arg cwd "$puppy_dir" \
        --arg created_at "$now" --arg last_started_at "$now" \
        '{name: $name, session_id: $session_id, cwd: $cwd, created_at: $created_at, last_started_at: $last_started_at}' \
        > "$reg_file"
    fi
    herdr workspace focus "$existing_ws" >/dev/null
    echo "Sesión '$name' ya estaba abierta (workspace $existing_ws), la he enfocado."
    return 0
  fi

  if [[ -n "$existing_ws" && "$fresh" -eq 1 ]]; then
    echo "Cerrando sesión previa '$name' ($existing_ws)..."
    herdr workspace close "$existing_ws" >/dev/null 2>&1 || true
  fi

  local uuid is_new created_at
  if [[ "$fresh" -eq 1 ]]; then
    uuid=$(gen_uuid)
    is_new=1
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  elif [[ -f "$reg_file" ]]; then
    uuid=$(jq -r '.session_id' "$reg_file")
    is_new=0
    created_at=$(jq -r '.created_at' "$reg_file")
  else
    uuid=$(gen_uuid)
    is_new=1
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  local ws_json
  ws_json=$(herdr workspace create --cwd "$puppy_dir" --label "$name" --focus)
  if echo "$ws_json" | jq -e '.error' >/dev/null 2>&1; then
    echo "error creando el workspace de la sesión '$name': $(echo "$ws_json" | jq -r '.error.message')" >&2
    exit 1
  fi
  local ws_id pane_id
  ws_id=$(echo "$ws_json" | jq -r '.result.workspace.workspace_id // .result.workspace_id')
  pane_id=$(echo "$ws_json" | jq -r '.result.pane.pane_id // .result.root_pane.pane_id')

  local started=0 attempt
  for attempt in 1 2 3 4 5; do
    if [[ "$is_new" -eq 1 ]]; then
      if herdr agent start "$name" --kind claude --pane "$pane_id" -- --session-id "$uuid" --name "$name" >/dev/null 2>&1; then
        started=1; break
      fi
    else
      if herdr agent start "$name" --kind claude --pane "$pane_id" -- --resume "$uuid" --name "$name" >/dev/null 2>&1; then
        started=1; break
      fi
    fi
    sleep 1
  done
  if [[ "$started" -ne 1 ]]; then
    echo "error: workspace creado (id $ws_id) pero no se pudo arrancar Claude Code en el pane $pane_id" >&2
    exit 1
  fi

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n --arg name "$name" --arg session_id "$uuid" --arg cwd "$puppy_dir" \
    --arg created_at "$created_at" --arg last_started_at "$now" \
    '{name: $name, session_id: $session_id, cwd: $cwd, created_at: $created_at, last_started_at: $last_started_at}' \
    > "$reg_file"

  if [[ "$is_new" -eq 1 ]]; then
    echo "Sesión '$name' arrancada en workspace $ws_id (pane $pane_id), cwd=$puppy_dir"
  else
    echo "Sesión '$name' reanudada en workspace $ws_id (pane $pane_id), cwd=$puppy_dir"
  fi
}

# Closes the workspace if open; leaves the registry file alone (the slot
# stays resumable later). Silent no-op (not an error) if it wasn't open —
# `forget` relies on that to chain stop+delete unconditionally.
stop_session() {
  local name="$1"
  local existing_ws
  existing_ws=$(herdr workspace list 2>/dev/null | jq -r --arg n "$name" '.result.workspaces[] | select(.label==$n) | .workspace_id' | head -1)
  if [[ -z "$existing_ws" ]]; then
    echo "La sesión '$name' no está abierta."
    return 0
  fi

  local pane_id
  pane_id=$(herdr pane list --workspace "$existing_ws" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
  if [[ -n "$pane_id" ]]; then
    local pid
    pid=$(herdr pane process-info --pane "$pane_id" 2>/dev/null \
      | jq -r '.result.process_info.foreground_processes[]? | select(.name=="claude") | .pid' | head -1)
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi

  herdr workspace close "$existing_ws" >/dev/null 2>&1 || true
  echo "Sesión '$name' detenida (workspace $existing_ws cerrado)."
}

forget_session() {
  local name="$1" force="${2:-0}"
  local reg_file="$sessions_dir/$name.json"

  stop_session "$name" >/dev/null || true

  if [[ ! -f "$reg_file" ]]; then
    echo "error: no existe la sesión '$name' (sin registro en $reg_file)" >&2
    exit 1
  fi

  if [[ "$force" -ne 1 ]]; then
    if [[ -t 0 && -t 1 ]]; then
      read -r -p "¿Borrar el registro de la sesión '$name' ($reg_file)? Esto no se puede deshacer. [y/N]: " answer
      case "$answer" in
        y|Y|yes|si|sí) ;;
        *) echo "Cancelado."; exit 0 ;;
      esac
    else
      echo "error: 'forget' borra el registro de la sesión permanentemente; usa --force en modo no interactivo si estás seguro." >&2
      exit 1
    fi
  fi

  rm -f "$reg_file"
  echo "Sesión '$name' olvidada (registro borrado)."
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  gen-uuid)
    gen_uuid
    ;;
  list)
    list_sessions
    ;;
  start)
    if [[ $# -lt 1 ]]; then
      echo "uso: sessions.sh start <name> [--fresh]" >&2
      exit 1
    fi
    name="$1"; shift
    fresh=0
    [[ "${1:-}" == "--fresh" ]] && fresh=1
    start_session "$name" "$fresh"
    ;;
  stop)
    if [[ $# -lt 1 ]]; then
      echo "uso: sessions.sh stop <name>" >&2
      exit 1
    fi
    stop_session "$1"
    ;;
  forget)
    if [[ $# -lt 1 ]]; then
      echo "uso: sessions.sh forget <name> [--force]" >&2
      exit 1
    fi
    name="$1"; shift
    force=0
    [[ "${1:-}" == "--force" ]] && force=1
    forget_session "$name" "$force"
    ;;
  *)
    echo "uso: sessions.sh gen-uuid|list|start <name> [--fresh]|stop <name>|forget <name> [--force]" >&2
    exit 1
    ;;
esac
