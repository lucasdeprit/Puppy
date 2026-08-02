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

# puppy_project_path_file <slug> — path to the file that records the
# original absolute project directory for the given slug, so it can be
# recovered later (e.g. by the `puppy start` picker) even with no workspace
# open and no task spawned yet to read a project_dir field from.
puppy_project_path_file() {
  local slug="$1"
  echo "$HOME/.local/share/puppy/projects/$slug/project_path"
}

# puppy_data_dir [dir] — ~/.local/share/puppy/projects/<slug>/data for the
# given project dir (default: puppy_project_dir). Creates it if missing, and
# (re)records the project's original path alongside it.
puppy_data_dir() {
  local dir="${1:-$(puppy_project_dir)}"
  local slug data_dir
  slug=$(puppy_project_slug "$dir")
  data_dir="$HOME/.local/share/puppy/projects/$slug/data"
  mkdir -p "$data_dir"
  printf '%s\n' "$dir" > "$(puppy_project_path_file "$slug")"
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

# puppy_all_projects — one line "<slug>\t<project-path-or-empty>" per known
# project (one with a data dir on disk), regardless of whether it currently
# has a herdr workspace open. Used by the `puppy start` picker and `puppy
# forget`.
puppy_all_projects() {
  local base="$HOME/.local/share/puppy/projects"
  [[ -d "$base" ]] || return 0
  local slug_dir slug path_file path
  for slug_dir in "$base"/*/; do
    [[ -d "${slug_dir}data" ]] || continue
    slug="$(basename "$slug_dir")"
    path_file=$(puppy_project_path_file "$slug")
    path=""
    [[ -f "$path_file" ]] && path=$(<"$path_file")
    printf '%s\t%s\n' "$slug" "$path"
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

# puppy_list_sessions — pure data enumerator, no prompts: everything goes to
# stdout, nothing is asked interactively. Combines the herdr workspaces whose
# label matches "^puppy-" (open right now) with the known projects that have
# a saved data dir (via puppy_all_projects), deduplicated by slug — a session
# that's both open and has saved data appears exactly once.
#
# Output contract: one TSV line per known puppy session, fields separated by
# literal tabs, in this exact order:
#
#   <slug>\t<path-or-empty>\t<workspace_id-or-empty>\t<alive:0-or-1>\t<has_history:0-or-1-or-?>
#
#   - slug:         the project slug (see puppy_project_slug).
#   - path:         the known project_path for that slug, or empty if it was
#                    never recorded (old orphaned sessions).
#   - workspace_id: the open herdr workspace id for that slug's "puppy-<slug>"
#                    label, or empty if there's no workspace open right now.
#   - alive:        1 if there's a workspace AND puppy_workspace_alive says
#                    it has a live claude process in it; 0 otherwise
#                    (including "no workspace at all"). ALWAYS derived via
#                    puppy_workspace_alive — never trust herdr's raw
#                    agent_status for this: a workspace can stay "open" in
#                    herdr with its claude process already dead (e.g. a pane
#                    left running /bin/bash in the foreground, which herdr
#                    reports as agent_status "unknown" but is not a live
#                    session), so agent_status alone would lie here.
#   - has_history:  0 or 1 from puppy_claude_history_exists "$path" when path
#                    is known; the literal character "?" when path is empty,
#                    since history can't be checked without knowing the
#                    original directory.
#
# Parsing note for callers: path and workspace_id are frequently empty, and
# `IFS=$'\t' read -r a b c d e` silently collapses runs of empty tab-fields
# in bash (tab counts as "IFS whitespace" and gets collapsed even when IFS is
# set to a lone tab — confirmed empirically, not just theoretical). Parse
# each line as a whole (`IFS= read -r line`) and split fields with
# `${line%%$'\t'*}` / `${line#*$'\t'}` instead — see puppy_pick_session below
# for a worked example.
puppy_list_sessions() {
  local base="$HOME/.local/share/puppy/projects"
  local ws_lines
  ws_lines=$(herdr workspace list 2>/dev/null | jq -c '.result.workspaces[]? | select(.label | test("^puppy-"))')

  # slug -> project path, from every known project with saved data.
  local -A known_path=()
  local proj slug path
  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    slug="${proj%%$'\t'*}"
    path="${proj#*$'\t'}"
    known_path["$slug"]="$path"
  done < <(puppy_all_projects)

  local -A seen=()
  local ws ws_id label cwd alive has_history
  if [[ -n "$ws_lines" ]]; then
    while IFS= read -r ws; do
      [[ -z "$ws" ]] && continue
      ws_id=$(echo "$ws" | jq -r '.workspace_id')
      label=$(echo "$ws" | jq -r '.label')
      cwd=$(echo "$ws" | jq -r '.worktree.checkout_path // empty')
      slug="${label#puppy-}"
      seen["$slug"]=1

      path="${known_path[$slug]:-$cwd}"

      alive=0
      puppy_workspace_alive "$ws_id" && alive=1

      if [[ -n "$path" ]]; then
        has_history=0
        puppy_claude_history_exists "$path" && has_history=1
      else
        has_history="?"
      fi

      printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$path" "$ws_id" "$alive" "$has_history"
    done <<< "$ws_lines"
  fi

  local s
  for s in "${!known_path[@]}"; do
    [[ -n "${seen[$s]:-}" ]] && continue
    path="${known_path[$s]}"
    if [[ -n "$path" ]]; then
      has_history=0
      puppy_claude_history_exists "$path" && has_history=1
    else
      has_history="?"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$path" "" "0" "$has_history"
  done
}

# puppy_pick_session [--all|--open] — generic interactive picker built on top
# of puppy_list_sessions. With --open, only sessions with alive=1 are listed
# and selectable (e.g. there's no point offering to "stop" something that's
# already closed); with --all (the default, same as no flag), every known
# session is listed.
#
# Output contract: prints the numbered menu and every prompt to stderr (same
# style/tone as bin/puppy's puppy_pick_project_dir), and prints ONLY the
# chosen session's slug to stdout — never a path. Callers decide what to do
# with the slug, including resolving its path if they need it. This function
# does not support typing a free-form path for a new project; that's specific
# to `puppy start` and stays in puppy_pick_project_dir. Returns 1 (with a
# clear stderr message) if there's nothing to list, or the user doesn't pick
# a valid option.
puppy_pick_session() {
  local filter="all"
  case "${1:-}" in
    --open) filter="open" ;;
    --all|"") filter="all" ;;
    *) echo "error: puppy_pick_session: opción desconocida '$1'" >&2; return 1 ;;
  esac

  local -a slugs=()
  local -a paths=()
  local idx=1
  local line rest slug path ws_id alive has_history status_txt history_txt

  # Parsed field-by-field with parameter expansion rather than
  # `IFS=$'\t' read -r a b c d e`: bash's word-splitting treats tab as "IFS
  # whitespace" and collapses runs of it even when IFS is set to a lone tab,
  # which silently eats the empty path/workspace_id fields puppy_list_sessions
  # emits. Whole-line read + %% / # expansion (same technique already used
  # above for puppy_all_projects's 2-field TSV) sidesteps that entirely.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="$line"
    slug="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    path="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    ws_id="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    alive="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    has_history="$rest"
    [[ "$filter" == "open" && "$alive" != "1" ]] && continue

    if [[ -n "$ws_id" ]]; then
      if [[ "$alive" == "1" ]]; then
        status_txt="abierto, vivo"
      else
        status_txt="abierto, sin proceso claude"
      fi
    else
      status_txt="cerrado"
    fi
    case "$has_history" in
      1) history_txt=", con historial" ;;
      0) history_txt=", sin historial" ;;
      *) history_txt="" ;;
    esac

    slugs[$idx]="$slug"
    paths[$idx]="$path"
    if [[ -n "$path" ]]; then
      printf "  %d) [%s%s] %s — %s\n" "$idx" "$status_txt" "$history_txt" "$slug" "$path" >&2
    else
      printf "  %d) [%s%s] %s (ruta desconocida)\n" "$idx" "$status_txt" "$history_txt" "$slug" >&2
    fi
    idx=$((idx + 1))
  done < <(puppy_list_sessions)

  if [[ "$idx" -eq 1 ]]; then
    if [[ "$filter" == "open" ]]; then
      echo "error: no hay ninguna sesión de Puppy abierta." >&2
    else
      echo "error: no hay ninguna sesión de Puppy conocida." >&2
    fi
    return 1
  fi

  local answer
  read -r -p "Elige un número: " answer

  if [[ ! "$answer" =~ ^[0-9]+$ ]] || [[ -z "${slugs[$answer]+set}" ]]; then
    echo "error: no se eligió ninguna sesión válida." >&2
    return 1
  fi

  echo "${slugs[$answer]}"
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
