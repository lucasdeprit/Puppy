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

- `puppy start [<name>] [--fresh]` — opens (or focuses) a named puppy
  session. With no name, in a tty it shows a picker of registered
  sessions (plus the option to create a new one); non-interactively it
  defaults to the name `puppy`. `--fresh` starts that name over with a
  brand-new conversation instead of resuming.
- `puppy stop [<name>]` — closes that session's workspace (its
  registration stays, so it's resumable later). With no name, only works
  if exactly one session is open.
- `puppy forget <name> [--force]` — stops the session (if open) and
  deletes its registration entirely. Prompts for confirmation in a tty;
  requires `--force` otherwise.
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
