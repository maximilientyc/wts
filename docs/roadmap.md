# Roadmap

What the review of 2026-09-28 left open, once 1.4.1 (the destructive verbs take
nothing on trust) and 1.5.0 (the agent's own hooks, a bell and a banner,
since-when) had shipped. Ordered by impact over size; S is an afternoon, M a
day or two. Each item names the code it builds on, so the estimate is checkable.
The rules of CLAUDE.md hold throughout: the model is never called from `ls`,
the switcher or a hook; `wts status --json` and `wts log` are contracts.

Item 1, *read the data wts already writes* (previous attempts in the task's
context, briefs and notes in the switcher preview, `gc --all` and a REPO
column), shipped after 1.5.2. Item 2, *the command surface* (`wts doctor`, the
typo guard, `--help` per command and exit codes, failures that say why, Ctrl-C
while naming, a shorter SessionStart hook, one word per action, the cost said
once, docs and completion, and gc scoped to what wts made, `--all-branches`
for the rest), shipped with it. Then *agent friendly*: no Things read, picker or
attach without a terminal, `--json` on every listing, `wts send`, `wait` and
`tail`, notes at each turn, real file overlap from a `PostToolUse` hook, a task
link the agent can judge, and the wts skill. Then *tokens and cost per session
and per task*: summed from the transcripts by `wts brief` and at teardown into
a `usage` table, shown by `wts ls --wide`, `wts status --json`, `wts log` and
`wts task show`. Then *PR, CI and review state per session*: `wts pr
--refresh` and a `pr_state` cache, the switcher's PR column, merged last, and
`merged` by patch-id rather than ancestry. Then *Linux CI* (`ubuntu-latest`
next to `macos-latest`) with five items of the list below: preview targets,
the stale guard, unknown agent states, session names, the task screen's
branch prefix.

## 1. Then, by what you feel first

- **Filter and group the switcher at ten sessions and more. [M]** A `ctrl-g`
  toggle between "needs me" (blocked, failed, idle) and "all", a repository
  prefix or colour per row, per-state counts in the header. Inside the existing
  `--list` reload and the three-TAB-field row contract.
- **Related past work at creation, without a task. [M]** FTS5 over
  `archive(prompt, title, files, retro_*)`; at `wts "<phrase>"` the two or three
  best same-repository matches go into `.wts/context.md` under "Related past
  work". A database read only.

## Known, small, and not yet done

From the correctness audit; none loses data, each is a wrong result on a path
you can hit.

- One agent per worktree, picked with `first`: a `blocked` agent can hide
  behind a `done` one, which also weakens gc's busy check.
- A branch cut from a local base that carries commits already squash-landed
  upstream reads merged (gc: dead) before its agent commits anything: the
  new-branch test in `merge_is_new` requires zero commits ahead of
  `origin/<base>`. The reflog alone ("Created from", nothing since) would say
  new, except for a branch tracking its own remote, which may hold real work.
- A multi-line `context` shifts the collector's line-per-field stream; two
  simultaneous phrase creations can share a slug; a stale
  `~/.claude/sessions/<pid>.json` is not checked for pid liveness and can point
  the preview at an old pane after a tmux restart.
