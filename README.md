# 🐩 Puppy

Puppy is a lead-agent orchestration tool built on top of [herdr](https://herdr.dev)
(a terminal workspace manager for AI coding agents). Named after Bilbao's
famous flower sculpture — a giant dog made of blooming flowers — Puppy
sends out **pups** to fetch and solve tasks, one per isolated git worktree,
while you keep talking to the main Puppy without waiting around.

## Concepts

- **Puppy** — the main agent (this one, running in `~/puppy`). Orchestrates,
  never touches real repos directly.
- **Pup** — a worker: a Claude Code agent started in its own isolated git
  worktree, given a prompt, and left to work. One pup per task.
- A pup reports back to Puppy **automatically** when it finishes (`done`),
  gets stuck (`blocked`), or ends up in an unclear state (`unknown`) — no
  polling required on Puppy's part.

## How it works

1. `puppy spawn` creates a git worktree for a task, starts a Claude Code
   pup inside it (with `--permission-mode acceptEdits`, so it can edit
   files in its own worktree without interactive approval), and submits
   the prompt. It returns immediately — it does not wait for the pup to
   finish.
2. In the background, `watch-pup.sh` waits on the pup's state and, the
   moment it resolves, injects a message directly into Puppy's own herdr
   pane via `herdr agent prompt` — a real, automatic notification, not a
   log you have to check.
3. Once a pup is done, the default path to land its work is `puppy pr`
   (push + `gh pr create`) — **not** a direct merge. Nothing merges to
   `main` on Puppy's own initiative.
4. Worktrees are only removed (`puppy rm`) on an explicit decision to
   discard the branch (PR merged/closed, or you review and say so) — never
   automatically just because a pup reached `done`.

## Prerequisites

- [herdr](https://herdr.dev) running (`herdr status`) — Puppy runs *inside*
  a herdr session and relies on `$HERDR_PANE_ID` to know where to send
  notifications back.
- `jq`, `gh` (authenticated — `gh auth status`).
- The `claude` herdr integration installed: `herdr integration install claude`.

## Install / invoke

`~/.local/bin/puppy` is a symlink to `bin/puppy` in this repo. As long as
`~/.local/bin` is on your `PATH`, `puppy` is callable from anywhere — no
`cd` required.

## Commands

```
puppy spawn <pup-id> <repo-path> <branch> <prompt...>   launch a pup (worktree + worker)
puppy pr <pup-id> [-- args for gh pr create]             push + open a PR
puppy rm <pup-id> [--force]                               remove a pup's worktree + record
puppy supervise [pup-id ...]                              block (polling) until some pup resolves
puppy ls                                                  list registered pups and their status
puppy status <pup-id>                                     full metadata for one pup
```

### Example

```
puppy spawn fix-login ~/development/nextjs/burmuin/burmuin fix/issue-141-login \
  "Fix the login redirect bug described in issue #141"
```

Keep working / talking to Puppy. When the pup finishes, you'll see:

```
🐶 El pup 'fix-login' (burmuin#fix/issue-141-login) ha terminado con estado: done. ...
```

Then, once reviewed:

```
puppy pr fix-login
puppy rm fix-login    # only after the PR is merged/closed, or you decide to discard it
```

## Context auto-detection

`puppy spawn` checks the target repo (by convention, not project-specific)
for:

- `open-knowledge/map.md` — if present, the pup's prompt is prefixed with
  an instruction to read it first and follow its rules/task router.
- `.engram/config.json` — if present, the pup is told to `engram search`
  before starting and `engram save` after meaningful changes.

This lets Puppy plug into a repo's existing knowledge base or memory
system **without modifying the repo itself** — useful for repos that
already run their own agent workflow (e.g. an OpenCode + Engram setup)
that should keep working unchanged, in parallel.

## Known limitations

- `puppy supervise` polls `data/tasks/*.json` rather than using bash
  `wait -n` on background jobs. This is deliberate: the Bash tool that
  drives Puppy (via Claude Code) does not persist shell/job-table state
  across tool calls, so a job backgrounded in one call isn't waitable in
  the next. The push notification from `watch-pup.sh` is the primary
  mechanism; `supervise` is only for an explicit synchronous wait.
- Pups run with `--permission-mode acceptEdits`: file edits are automatic,
  but risky Bash commands can still prompt for approval and leave the pup
  `blocked`. That's expected, not a bug — it's the same signal a human
  reviewer would want surfaced.
- No hard technical lock stops Puppy from writing to a real repo directly
  or force-removing a worktree — those are prompt-level rules in
  `AGENTS.md`, by design (kept intentionally lightweight rather than
  enforced via permissions).

## Files

```
puppy/
├── AGENTS.md              operating rules for the Puppy agent itself
├── README.md               this file
├── bin/
│   ├── puppy                global dispatcher
│   ├── spawn-pup.sh         create worktree + start pup + send prompt
│   ├── watch-pup.sh         background: wait for pup state, notify Puppy
│   ├── supervise.sh         optional synchronous wait (polling)
│   ├── open-pr.sh           push + gh pr create
│   └── remove-pup.sh        remove a pup's worktree (with safety checks)
└── data/
    ├── tasks/<pup-id>.json  per-pup metadata (gitignored)
    └── events.log           append-only state history (gitignored)
```
