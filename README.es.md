# Puppy

Read this in English: [README.md](README.md)

Puppy es un agente principal que orquesta **pups**: workers Claude Code que
corren aislados en sus propios git worktrees, gestionados a través de
[herdr](https://github.com/anthropics). Puppy nunca toca los repos reales
directamente — delega todo cambio de código en los pups.

## Instalación

Symlinkea el entry point en tu `PATH`:

```sh
ln -s "$(pwd)/bin/puppy" ~/.local/bin/puppy
```

Asegúrate de que `~/.local/bin` está en tu `PATH`. `puppy` queda entonces
llamable desde cualquier directorio.

## Comandos

- `puppy start [--resume|--fresh]` — abre (o enfoca) la sesión del puppy
  principal; sin flag, pregunta si hay una sesión previa que reanudar.
- `puppy stop` — termina el proceso de puppy y cierra su workspace.
- `puppy spawn <pup-id> <repo-path> <branch> <prompt...>` — lanza un pup
  (worktree + worker).
- `puppy pr <pup-id> [-- <args extra de gh pr create>]` — pushea la rama y
  abre un PR.
- `puppy rm <pup-id> [--force]` — borra el worktree de un pup y su registro.
- `puppy supervise [pup-id ...]` — bloquea (sondeando) hasta que resuelva
  alguno de los pups indicados.
- `puppy ls` — lista los pups registrados y el estado de la sesión de
  puppy.
- `puppy status <pup-id>` — muestra la metadata completa de un pup.
- `puppy watchers` — lista los watch-pup.sh vivos y detecta huérfanos.
