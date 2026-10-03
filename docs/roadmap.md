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
for the rest), shipped with it.

## 1. Agent friendly

Read from the other side: what wts is like for the Claude agent in the pane,
with a Bash tool whose stdin and stdout are not a terminal and `$TMUX` set.
Two uses. An agent working *in* a session reads its context and coordinates
with its siblings: that works — the hook says who it is, which task, who else
is on the repository, and `wts db set`, `wts task note` and `wts status --json`
answer at the first try. An agent *driving* wts — "start three sessions on
these tasks and tell me when they are done" — finds nothing built for it: every
verb that acts (reply, wait, read the result) lives in the popup. Ordered so
that each block makes the next one safe to use.

### 1.1 Never in the way [S each]

- **No read of Things from an agent.** The hook tells every agent to run
  `wts task show <id>`, and `setup claude` allows it without a prompt; with a
  Things id it snapshots, which runs `wts-things show` (`wts-task` `snapshot`) —
  a read of another app's container, the very thing CLAUDE.md reserves for a
  command the user typed (macOS raises its permission dialog on it). `show`
  reads wts's database only; `--refresh` reads Things, explicitly.
- **No tty, no question.** Without a terminal, every picker and every
  confirmation exits 2 and names what to pass instead (`pass --task <id>, see
  wts task ls --json`). Today a bare `--task` or `task link` reads Things
  *before* opening an fzf that cannot draw, and the document picker falls back
  to a `read` on the agent's stdin. `wts rm` already refuses this way.
- **Create without attaching.** The normal flow ends with `switch-client` (or a
  `tmuxinator start` that attaches): run from an agent's pane it can move the
  human's terminal to the new session. `--detach`, documented, and implied when
  stdin is not a terminal; `WTS_NO_ATTACH` is the internal spelling of it today.
  The result on stdout as JSON: `{name, branch, worktree, task}` — a proposed
  name is only known once wts has made it unique.
- **Permissions for what agents reach for.** `setup claude` allows `db`,
  `task note`, `task show` and `status`; an agent's first reflexes are `wts ls`,
  `wts task ls`, `wts doc ls`, `wts log`, `wts help`, `wts doctor`, and each one
  waits on a prompt. Add the read-only verbs; never `rm`, `gc`, `stop`.

### 1.2 Output a program can read [M]

- **`--json` on every listing**: `task ls` and `task show` (today `◆` rows),
  `doc ls` and `doc show` (columns cut at 40), `brief --cached` (the `briefs`
  table, no model call), `gc --json` (the dry run's plan: what would go, and
  why), `doctor --json`. Each one versioned like `wts log`, values from closed
  lists, documented in the README next to `status --json`.
- **Exit codes as a contract**: 0 done, 1 failed, 2 usage — what #31 put in
  place, written down per command.

### 1.3 Drive other agents [M]

- **`wts send <session> "<text>"`**: the switcher's reply mode as a command,
  for an agent that delegated. Into the agent's pane, and refused when that
  pane is unknown — today reply mode and `ctrl-e` fall back to the session's
  *active* pane, the editor in the default layout. One fix for both.
- **`wts wait <session>... --until idle|blocked|done [--timeout <s>]`**: block
  until each named session reaches a state, from `agent_events` (the hooks
  date every transition already); exit 0, or 1 on timeout with the states it
  saw. This is what turns "start three sessions" into "start three sessions and
  collect their results".
- **`wts tail <session> [-n <k>]`**: the agent's last messages, from its
  transcript — `wts-brief` already finds the transcript and parses it — rather
  than a `capture-pane` of a TUI. With `--json`.

### 1.4 Coordinate with siblings

- **Notes as they are written. [M]** The hook runs at SessionStart only: a note
  a sibling leaves an hour later reaches nobody who does not poll. On
  `UserPromptSubmit`, `wts-hook` prints one line — "2 new notes on this
  repository since your last turn: …", capped, same repository, only when there
  are some. A deliberate exception to the hook that never prints (Claude Code
  adds that stdout to the conversation, which is the point here); CLAUDE.md
  says so where it states the rule.
- **Real file overlap. [M]** The files a session touched are computed at
  teardown only (`wts-retro collect`). A `PostToolUse` hook on
  `Edit|Write|MultiEdit` inserting `(session, path, at)` into a `touches` table
  gives exact overlap cheaply: the SessionStart hook and the note line above
  name the siblings on the same paths, the switcher marks them. This is what
  would make the hook's directives about overlap unnecessary.
- **A task link the agent can judge. [S]** A session keeps the task it was
  created for while its work moves on: this roadmap was written by a session
  still introduced as "Roadmap wts part 1". The hook says when and how the link
  was made, and how to change it (`wts task link <id>`, `wts task new`).

### 1.5 Discoverable on demand [M]

- **The agent-facing surface as a Claude Code skill.** Keep the hook to a few
  lines (who I am, same-repository siblings, overlap); package `wts db`,
  `wts task note`, `wts status --json`, the overlap query and the verbs of 1.3
  as a skill agents load when they need it. It gives `status --json` and the
  JSON of 1.2 their documented consumer, and 1.3 is what makes it worth loading.

## 2. Then, by what you feel first

- **PR, CI and review state per session. [M]** No PR column; `merged` is in the
  JSON but hidden, and ancestry-only (a squash merge reads `false`, while gc has
  the right patch-id test); `wts pr` only opens a browser. `wts pr --refresh`,
  explicit or on a slow timer and never the 2 s tick, caches
  `gh pr view --json number,state,reviewDecision,statusCheckRollup,mergedAt`
  in a `pr_state` table; the switcher shows `#42 ✓` / `#42 ✗ci` / `#42 chg` /
  `merged`, sorts merged last and offers `ctrl-d` there. Reuses the `gh`
  detection in `wts-keys` and the transcript `pr-link` parsing in `wts-brief`.
- **Tokens and cost per session and per task. [M]** Nothing reads
  `message.usage` or the model from transcripts, although `wts-retro`'s header
  promises "what it cost". `wts-brief` and `wts-retro collect` already read the
  transcript once: sum input, output and cache tokens and the model there,
  store them in a side table (a new column never appears on an existing
  database, `db_init` is `CREATE TABLE IF NOT EXISTS`), show them in `wts log`
  and `wts ls --wide`.
- **Filter and group the switcher at ten sessions and more. [M]** A `ctrl-g`
  toggle between "needs me" (blocked, failed, idle) and "all", a repository
  prefix or colour per row, per-state counts in the header. Inside the existing
  `--list` reload and the three-TAB-field row contract.
- **Related past work at creation, without a task. [M]** FTS5 over
  `archive(prompt, title, files, retro_*)`; at `wts "<phrase>"` the two or three
  best same-repository matches go into `.wts/context.md` under "Related past
  work". A database read only.
- **Linux CI. [S]** `ubuntu-latest` next to `macos-latest`; gate the Things
  checks on `WTS_NO_THINGS=1`. It would have caught `shasum` and `unixepoch()`
  (SQLite 3.38) already.

## Known, small, and not yet done

From the correctness audit; none loses data, each is a wrong result on a path
you can hit.

- The task screen's branch hint strips and promises `feature/`; the built-in
  layout has no prefix, so `feature/foo` typed there yields branch `foo`.
  Read the prefix with `branch_prefix_of`.
- Two preview calls use a bare session name as tmux target; a session named
  `0` or `1` is tried as a window first. `tmux_target()` already builds `=name:`.
- The stale guard hashes an empty capture when `capture-pane` fails, so a dead
  pane reads `stuck?` for good and gc holds its worktree; without `shasum`
  (some Linux) it is silently off. Check the capture's status; fall back to
  `sha1sum` or `cksum`.
- Unknown `claude agents` state values pass straight into the public JSON,
  against the closed list CLAUDE.md promises. Map them to `null`, log once.
- Session names are not validated: tmux rewrites `.` and `:`, `has-session -t
  "=…"` never matches, and the idempotent re-run starts a duplicate.
- One agent per worktree, picked with `first`: a `blocked` agent can hide
  behind a `done` one, which also weakens gc's busy check.
- A multi-line `context` shifts the collector's line-per-field stream; two
  simultaneous phrase creations can share a slug; a stale
  `~/.claude/sessions/<pid>.json` is not checked for pid liveness and can point
  the preview at an old pane after a tmux restart.
