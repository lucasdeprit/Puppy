# Puppy

Leer en inglés: [README.md](README.md)

Puppy es un agente principal que orquesta **pups**: workers Claude Code que
corren aislados en sus propios git worktrees, gestionados a través de
[herdr](https://herdr.dev). Puppy nunca toca los repos reales
directamente — delega todo cambio de código en los pups.

## Instalación

Symlinkea el entry point en tu `PATH`:

```sh
ln -s "$(pwd)/bin/puppy" ~/.local/bin/puppy
```

Asegúrate de que `~/.local/bin` está en tu `PATH`. `puppy` queda entonces
llamable desde cualquier directorio.

## Comandos

- `puppy start [<name>] [--fresh]` — abre (o enfoca) una sesión nombrada
  del puppy principal. Sin nombre, en tty muestra un picker con las
  sesiones registradas (con opción de crear una nueva); sin tty usa por
  defecto el nombre `puppy`. `--fresh` arranca esa sesión desde cero con
  una conversación nueva en vez de reanudar.
- `puppy stop [<name>]` — cierra el workspace de esa sesión (su registro
  queda, sigue siendo reanudable). Sin nombre, sólo funciona si hay
  exactamente una sesión abierta.
- `puppy forget <name> [--force]` — detiene la sesión (si está abierta) y
  borra su registro por completo. Pide confirmación en tty; requiere
  `--force` si no.
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
