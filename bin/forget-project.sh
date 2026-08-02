#!/usr/bin/env bash
set -uo pipefail

# forget-project.sh [project-dir | --slug <slug>] [--path <dir>] [--force]
#                    [--yes] [--keep-history]
#
# Stops Puppy's session para el proyecto dado (igual que `puppy stop`) y
# borra su bookkeeping propio (~/.local/share/puppy/projects/<slug>/):
# tasks, events.log, la ruta recordada, todo. No toca el worktree ni la rama
# de ningún pup.
#
# Por defecto TAMBIÉN purga el historial real de conversación de Claude Code
# para ese proyecto (transcripts, memoria, prompts en history.jsonl), vía
# `claude project purge`. Usa --keep-history para saltear esa purga y
# quedarte solo con el comportamiento de bookkeeping.
#
# Resolución del objetivo a olvidar (en este orden):
#   --slug <slug>       usa ese slug directo, sin tocar el filesystem —
#                        necesario para sesiones huérfanas sin ruta
#                        resolvible (ver --path más abajo).
#   <project-dir>        argumento posicional, resuelto con cd como antes.
#   (nada) + tty real     picker interactivo (puppy_pick_session --all).
#   (nada) + sin tty       error de uso.
#
# --path <dir> es un override aparte, solo para la purga de historial real:
# permite decirle a una sesión huérfana (sin project_path conocido) cuál era
# su ruta original, para poder purgar su historial aunque forget-project.sh
# no la use para nada del lado del bookkeeping/stop de puppy.
#
# Mismo patrón de warn-then-require-confirmation que remove-pup.sh para pups
# pendientes: --force saltea ESE aviso. La purga de historial real tiene su
# propio gate independiente: --yes (sin tty) o confirmación explícita (con
# tty). Son riesgos distintos, no se combinan en una sola flag.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/project.sh"

force=0
yes=0
keep_history=0
slug_arg=""
path_arg=""
project_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1; shift ;;
    --yes) yes=1; shift ;;
    --keep-history) keep_history=1; shift ;;
    --slug)
      [[ $# -ge 2 ]] || { echo "error: --slug requiere un valor" >&2; exit 1; }
      slug_arg="$2"; shift 2 ;;
    --path)
      [[ $# -ge 2 ]] || { echo "error: --path requiere un valor" >&2; exit 1; }
      path_arg="$2"; shift 2 ;;
    *)
      project_arg="$1"; shift ;;
  esac
done

if [[ -n "$slug_arg" && -n "$project_arg" ]]; then
  echo "aviso: se pasaron --slug y un argumento posicional a la vez; uso --slug ($slug_arg)." >&2
fi

if [[ -n "$slug_arg" ]]; then
  slug="$slug_arg"
elif [[ -n "$project_arg" ]]; then
  project_dir="$(cd "$project_arg" && pwd -P)" || {
    echo "error: '$project_arg' no es un directorio." >&2
    exit 1
  }
  slug=$(puppy_project_slug "$project_dir")
elif [[ -t 0 && -t 1 ]]; then
  slug=$(puppy_pick_session --all) || exit 1
else
  echo "uso: forget-project.sh [project-dir | --slug <slug>] [--path <dir>] [--force] [--yes] [--keep-history]" >&2
  exit 1
fi

project_root="$HOME/.local/share/puppy/projects/$slug"
data_dir="$project_root/data"

if [[ ! -d "$project_root" ]]; then
  echo "No hay datos guardados de Puppy para el slug '$slug'; nada que olvidar."
  exit 0
fi

# Ruta original conocida para este slug, si existe (puede no haber ninguna:
# sesión huérfana, ver --path arriba).
path_file=$(puppy_project_path_file "$slug")
known_path=""
[[ -f "$path_file" ]] && known_path=$(<"$path_file")

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
  echo "AVISO: hay pups sin terminar (ni done ni merged) en la sesión '$slug':" >&2
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

# Detener la sesión, igual que `puppy stop`. `stop` toma un directorio y
# deriva el slug/label de ahí, así que solo tiene sentido pasarle la ruta
# YA REGISTRADA para este slug (nunca el --path que el usuario haya dado a
# mano para la purga de historial: si esa ruta recordada fuera incorrecta,
# apuntaría a un workspace ajeno).
if [[ -n "$known_path" && -d "$known_path" ]]; then
  "$script_dir/puppy" stop "$known_path"
else
  echo "No se conoce (o ya no existe) la ruta original de la sesión '$slug'; omito 'puppy stop' (si tenía un workspace abierto, cerralo a mano)." >&2
fi

# Purga del historial real de Claude Code (comportamiento por defecto,
# saltable con --keep-history).
if [[ "$keep_history" -eq 1 ]]; then
  echo "--keep-history: no se toca el historial real de Claude Code, solo el bookkeeping de puppy."
else
  purge_path="${path_arg:-$known_path}"
  if [[ -z "$purge_path" ]]; then
    echo "No se conoce la ruta original de esta sesión; no se puede purgar su historial real. Si la recordás, volvé a correr con --path <ruta>." >&2
  else
    echo
    echo "Plan de purga del historial real de Claude Code para $purge_path (claude project purge --dry-run):"
    dry_run_output=$(claude project purge "$purge_path" --dry-run 2>&1)
    dry_run_status=$?
    echo "$dry_run_output"

    if [[ $dry_run_status -ne 0 ]]; then
      echo "error: 'claude project purge --dry-run' falló; no se purga el historial real (sí se sigue con el borrado del bookkeeping de puppy)." >&2
    else
      # Chequeo de colisión, obligatorio: cruzar cada ruta que el dry-run
      # tocaría (los directorios bajo ~/.claude/projects/<ruta-codificada>)
      # contra las sesiones de puppy conocidas (puppy_all_projects),
      # excluyendo la propia. `claude project purge` matchea por PREFIJO de
      # ruta, así que purgar un directorio padre se lleva puesto el
      # historial de subdirectorios que sean, ellos mismos, otro proyecto
      # de puppy vivo — reproducible ahora mismo: purgar
      # /home/puppy/development arrastra el historial de
      # /home/puppy/development/burmuin (slug burmuin-5746dfd6), que además
      # no tiene project_path grabado, así que el único modo de detectarlo
      # es recomputar su slug a partir de la ruta decodificada del dry-run,
      # no comparar contra una ruta registrada que no existe.
      collision_slug=""
      collision_path=""
      while IFS= read -r dirpath; do
        [[ -z "$dirpath" ]] && continue
        encoded_name="$(basename "$dirpath")"
        # Decodifica ~/.claude/projects/<encoded> de vuelta a una ruta:
        # "-" -> "/" (la misma codificación que puppy_claude_history_exists
        # usa en la otra dirección). Lossy si la ruta real tiene guiones
        # literales en algún componente, pero eso solo produce falsos
        # negativos (un slug que no matchea nada conocido), nunca falsos
        # positivos, porque el slug final depende de un hash.
        candidate="/${encoded_name#-}"
        candidate="${candidate//-//}"
        candidate_slug=$(puppy_project_slug "$candidate")

        while IFS= read -r proj; do
          [[ -z "$proj" ]] && continue
          other_slug="${proj%%$'\t'*}"
          other_path="${proj#*$'\t'}"
          [[ "$other_slug" == "$slug" ]] && continue
          if [[ -n "$other_path" ]]; then
            if [[ "$candidate" == "$other_path" || "$candidate" == "$other_path"/* ]]; then
              collision_slug="$other_slug"
              collision_path="$other_path"
              break
            fi
          elif [[ "$candidate_slug" == "$other_slug" ]]; then
            collision_slug="$other_slug"
            collision_path="$candidate"
            break
          fi
        done < <(puppy_all_projects)

        [[ -n "$collision_slug" ]] && break
      done < <(printf '%s\n' "$dry_run_output" | awk '/^[[:space:]]*dir:/ {print $2}')

      do_purge=1
      if [[ -n "$collision_slug" ]]; then
        echo >&2
        echo "AVISO: el historial que se purgaría incluye rutas de OTRA sesión de Puppy conocida:" >&2
        echo "  slug: $collision_slug" >&2
        echo "  ruta: $collision_path" >&2
        echo "Purgar el historial de '$slug' se llevaría puesto también, de forma IRREVERSIBLE, el historial real de '$collision_slug'." >&2
        confirmed_collision=0
        if [[ -t 0 && -t 1 ]]; then
          read -r -p "¿Confirmás que querés purgar igual, sabiendo que esto también borra el historial de '$collision_slug'? [y/N]: " answer
          case "$answer" in
            y|Y|yes|si|sí|s) confirmed_collision=1 ;;
            *) ;;
          esac
        fi
        # Este gate no acepta --yes: es un riesgo aparte y no salteable, no
        # combinable con la confirmación genérica de más abajo.
        if [[ "$confirmed_collision" -ne 1 ]]; then
          echo "Cancelo la purga del historial real por la colisión de arriba (queda como si hubieras pasado --keep-history); sigo solo con el borrado del bookkeeping de puppy." >&2
          do_purge=0
        fi
      fi

      if [[ "$do_purge" -eq 1 ]]; then
        proceed=0
        if [[ "$yes" -eq 1 ]]; then
          proceed=1
        elif [[ -t 0 && -t 1 ]]; then
          read -r -p "Esto va a purgar de forma IRREVERSIBLE el historial real de Claude Code para $purge_path. ¿Continuar? [y/N]: " answer
          case "$answer" in
            y|Y|yes|si|sí|s) proceed=1 ;;
            *) ;;
          esac
        else
          echo "Usa --yes si de verdad quieres purgar el historial real de $purge_path de forma irreversible (o --keep-history para no tocarlo)." >&2
        fi

        if [[ "$proceed" -eq 1 ]]; then
          claude project purge "$purge_path" -y
        else
          echo "Cancelo la purga del historial real; sigo solo con el borrado del bookkeeping de puppy." >&2
        fi
      fi
    fi
  fi
fi

rm -rf "$project_root"
echo "Sesión '$slug' olvidada: borrados sus datos guardados de puppy ($project_root)."
