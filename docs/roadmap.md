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
branch prefix. Then *the switcher at ten sessions and more*: per-state counts
on its first line, `ctrl-g` between what needs you and every row, a REPO
column once the sessions span two repositories. Then the first part of *agents
working together* (section 2): `wts send` looks at the agent before it types,
`wts wait` ends on an agent that quit or is stuck, a name used again starts
clean, and an agent writes its own notes only. Then its second part, *exact
delivery*: a `seen` table (schema 9) records what each agent was told, so a
note reaches every sibling once at any clock resolution, at its next turn or
edit; the first editor of a file hears of the second, and a session that
finishes is announced with its outcome and the notes it left.

## 1. Then, by what you feel first

- **Related past work at creation, without a task. [M]** FTS5 over
  `archive(prompt, title, files, retro_*)`; at `wts "<phrase>"` the two or three
  best same-repository matches go into `.wts/context.md` under "Related past
  work". A database read only.

## 2. Agents working together

From the audit of 2026-10-04: how the agents of different sessions cooperate
through the database, and what the person running them sees of it. What the
agents share reaches the others by a comparison of clocks, half of it one way
only, and almost none of it is on a screen.

- **You see what they share. [M]** Who sent what no longer needs a tag in
  the line: between agents, Claude Code's own messages (2.1.224 and later,
  what the skill now prefers to `wts send`) arrive marked with their sender,
  `wts-hook prompt` records them as `kind = message`, and `wts brief` and the
  retrospective leave them out of the author's words. `wts send` keeps
  `send-keys`, since no command line posts into another session's socket: a
  line it types is still indistinguishable from the author's, which matters
  only for scripts and terminals now. Left: `send` waiting a few seconds for
  the turn to start, which closes the race with a `wait` that returns before
  it has; `wts status --json` gaining `notes_unseen`, `overlap` (`touches`,
  plus the files each branch changed against its base, so an edit made from
  the shell counts) and `asked_by` (the last `kind = message` prompt's
  sender), shown in the switcher preview. Try on a real agent first: a send
  with a draft in the input box, after `/clear`, and whether an edit made by a
  subagent runs the hook.
- Later: an author on `task_notes` and their delivery during a session (an
  ALTER, and sessions on one task are siblings the notes already reach); a
  mark on the switcher's row (a 12th `--fzf` field); `wts feed`, one timeline
  of what the agents told each other (lossy until there is an event log:
  `archive.notes` has no timestamps, and `touches` go with their session).

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
- `registry_put` overwrites a row's worktree when the same name comes back in
  the same repository under another branch prefix or `WTS_WORKTREES_BASE`: the
  first worktree stays on disk, unregistered. `wts doc use` types into an
  agent's pane without looking at its state, as `wts send` did.
- ~~When `claude agents` does not list an agent and the events decide alone, an
  agent started again in the same pane reads `stopped` until its first prompt:
  `SessionStart` records no event, so the `end` of the previous conversation
  is still the last word. `wts send` then needs `--force`.~~ Shipped:
  `wts-hook start` on `SessionStart` records a `start` event, which reads
  `idle` after an `end`.

## Claude Code features considered

Looked at while adding `--name`, `transcript_path` and the `start` hook, and
not adopted. Each one would be revisited if the reason stops holding.

- **`--bare`** for the headless calls (`wts-name`, `wts-brief`, `wts-retro`):
  with it, `claude --help` says, "Anthropic auth is strictly ANTHROPIC_API_KEY
  or apiKeyHelper via --settings (OAuth and keychain are never read)", so on a
  subscription account those calls would get no answer. In the agent's pane it
  would also skip the hooks, which are what wts reads an agent's state, pane and
  news from.
- **`--worktree`**: Claude Code would create a worktree of its own, beside the
  one wts made, registered and will gc; one worktree has one owner.
- **Agent teams**: the members live inside one Claude Code process and share
  its checkout; wts's unit is a worktree and a pane each, which you can attach
  to, review and clean up on their own.
- **`--bg` and the Agent SDK**: an agent with no pane has nowhere to ask for a
  permission where you will see it, and `wts send`, `reply` and the switcher
  preview all work on the pane.
- **A blocking `Stop` hook** (exit 2, to keep a turn going until the notes are
  read or the tests pass): a wts hook always exits 0 (CLAUDE.md), and one that
  decides when an agent may stop takes the turn from you, and loops it on a bug.
- **Plugin packaging** of the hooks and the skill: they point at the install's
  own `libexec` (`opt/wts` under Homebrew) and `wts doctor` checks that; a
  plugin is a second channel, versioned apart from the formula.
