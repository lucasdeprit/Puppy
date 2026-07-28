# Puppy

Leer en español: [README.es.md](README.es.md)

Puppy is a main agent that orchestrates **pups**: Claude Code workers that
run isolated in their own git worktrees, managed through
[herdr](https://herdr.dev). Puppy itself never touches real repos
directly — it delegates all code changes to pups.

## Install

Symlink the entry point onto your `PATH`:

```sh
ln -s "$(pwd)/bin/puppy" ~/.local/bin/puppy
```

Make sure `~/.local/bin` is on your `PATH`. `puppy` is then callable from
any directory.

## Commands

- `puppy start [--resume|--fresh]` — opens (or focuses) the main puppy
  session; with no flag, asks whether to resume a previous session if one
  exists.
- `puppy stop` — kills the puppy process and closes its workspace.
- `puppy spawn <pup-id> <repo-path> <branch> <prompt...>` — launches a pup
  (worktree + worker).
- `puppy pr <pup-id> [-- <extra gh pr create args>]` — pushes the branch and
  opens a PR.
- `puppy rm <pup-id> [--force]` — deletes the pup's worktree and its
  registration.
- `puppy supervise [pup-id ...]` — blocks (polling) until one of the given
  pups resolves.
- `puppy ls` — lists registered pups and the puppy session status.
- `puppy status <pup-id>` — shows the full metadata for a pup.
- `puppy watchers` — lists live watch-pup.sh processes and detects orphans.
