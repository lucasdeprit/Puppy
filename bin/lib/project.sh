#!/usr/bin/env bash
# lib/project.sh — shared helpers for resolving the active project and its
# per-project data directory. Meant to be sourced by bin/puppy and the other
# bin/*.sh scripts, not run directly.
#
# Puppy's own installation (bin/, AGENTS.md) lives fixed at a single
# location, but the project it orchestrates over — and therefore where its
# per-pup state lives — varies per session. These helpers keep that
# resolution in one place instead of duplicated across scripts.

# Absolute, symlink-resolved path of the active project directory for this
# session: $PUPPY_PROJECT_DIR if set (the herdr workspace env var set by
# `puppy start <dir>`), otherwise $PWD for invocations outside a herdr pane.
puppy_project_dir() {
  local dir="${PUPPY_PROJECT_DIR:-$PWD}"
  (cd "$dir" && pwd -P)
}

# puppy_project_slug <dir> — basename(dir)-<8 hex chars of sha1(dir)>,
# stable for a given path so the same project always maps to the same data
# directory even if two projects share a basename.
puppy_project_slug() {
  local dir="$1"
  local base hash
  base="$(basename "$dir")"
  if command -v sha1sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$dir" | sha1sum | cut -c1-8)
  else
    hash=$(printf '%s' "$dir" | shasum | cut -c1-8)
  fi
  echo "${base}-${hash}"
}

# puppy_data_dir [dir] — ~/.local/share/puppy/projects/<slug>/data for the
# given project dir (default: puppy_project_dir). Creates it if missing.
puppy_data_dir() {
  local dir="${1:-$(puppy_project_dir)}"
  local slug data_dir
  slug=$(puppy_project_slug "$dir")
  data_dir="$HOME/.local/share/puppy/projects/$slug/data"
  mkdir -p "$data_dir"
  echo "$data_dir"
}

# puppy_all_data_dirs — one line per existing project data directory, for
# lookups/aggregation that span every active project rather than just the
# current one.
puppy_all_data_dirs() {
  local base="$HOME/.local/share/puppy/projects"
  [[ -d "$base" ]] || return 0
  local d
  for d in "$base"/*/data; do
    [[ -d "$d" ]] && echo "$d"
  done
}

# puppy_find_workspace_by_label <label> — prints the workspace_id of the
# (first) herdr workspace with the given label, if any.
puppy_find_workspace_by_label() {
  local label="$1"
  herdr workspace list | jq -r --arg label "$label" '.result.workspaces[] | select(.label==$label) | .workspace_id' | head -1
}

# puppy_workspace_first_pane <ws-id> — prints the workspace's first pane id,
# if any.
puppy_workspace_first_pane() {
  local ws_id="$1"
  herdr pane list --workspace "$ws_id" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty'
}

# puppy_pane_claude_pid <pane-id> — prints the pid of the "claude" process
# running in the given pane's foreground, if any (empty if there's none, or
# the pane doesn't exist).
puppy_pane_claude_pid() {
  local pane_id="$1"
  [[ -z "$pane_id" ]] && return 0
  herdr pane process-info --pane "$pane_id" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]? | select(.name=="claude") | .pid' | head -1
}

# puppy_workspace_alive <ws-id> — true if the workspace has a pane with a
# live "claude" process in it. A herdr workspace can outlive the process
# that ran inside it (e.g. it crashed without herdr closing the pane), so
# finding the workspace by label isn't enough to know there's a real session
# to resume.
puppy_workspace_alive() {
  local ws_id="$1"
  local pane_id pid
  pane_id=$(puppy_workspace_first_pane "$ws_id")
  [[ -z "$pane_id" ]] && return 1
  pid=$(puppy_pane_claude_pid "$pane_id")
  [[ -n "$pid" ]]
}

# puppy_claude_history_exists <dir> — true if Claude Code has at least one
# saved session (a *.jsonl file) on disk for the given project directory.
# Claude Code keeps sessions under ~/.claude/projects/<encoded-cwd>/, where
# <encoded-cwd> is the absolute project path with every "/" and "."
# replaced by "-" (verified empirically against this very repo's own
# ~/.claude/projects/ entries — not documented, so re-check if this ever
# stops matching).
puppy_claude_history_exists() {
  local dir="$1"
  local encoded session_dir f
  encoded=$(printf '%s' "$dir" | sed -e 's#[/.]#-#g')
  session_dir="$HOME/.claude/projects/$encoded"
  [[ -d "$session_dir" ]] || return 1
  for f in "$session_dir"/*.jsonl; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# puppy_find_task <pup-id> — searches tasks/<pup-id>.json across every
# project's data directory and prints the matching path on stdout. A pup
# can be managed (status/tell/rm/pr) from a session other than the one that
# created it, so lookups by id are never scoped to just the current project.
puppy_find_task() {
  local task_id="$1"
  local d f
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    f="$d/tasks/$task_id.json"
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done < <(puppy_all_data_dirs)
  echo "error: no se encontró un pup con id '$task_id' en ningún proyecto" >&2
  return 1
}
