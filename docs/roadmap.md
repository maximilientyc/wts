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

## 1. Then, by what you feel first

- **PR, CI and review state per session. [M]** No PR column; `merged` is in the
  JSON but hidden, and ancestry-only (a squash merge reads `false`, while gc has
  the right patch-id test); `wts pr` only opens a browser. `wts pr --refresh`,
  explicit or on a slow timer and never the 2 s tick, caches
  `gh pr view --json number,state,reviewDecision,statusCheckRollup,mergedAt`
  in a `pr_state` table; the switcher shows `#42 ✓` / `#42 ✗ci` / `#42 chg` /
  `merged`, sorts merged last and offers `ctrl-d` there. Reuses the `gh`
  detection in `wts-keys` and the transcript `pr-link` parsing in `wts-brief`.
- **Real file overlap between sibling agents. [M]** The hook tells each agent
  to "scan the sibling sessions for overlap" and gives it a branch, an 80-char
  prompt and a usually absent brief; the files a session touched are computed
  at teardown only (`wts-retro collect`). A `PostToolUse` hook on
  `Edit|Write|MultiEdit` inserting `(session, path, at)` into a `touches` table
  gives exact overlap cheaply: the hook names the siblings on the same paths,
  the switcher marks them. This is what would make the hook's directives
  about overlap unnecessary.
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
- **The agent-facing surface as a Claude Code skill. [M]** Keep the hook to
  five lines (who I am, same-repository siblings, overlap); package `wts db`,
  `wts task note`, `wts status --json` and the overlap query as a skill agents
  load on demand. It also gives `wts status --json` its documented consumer.
- **Linux CI. [S]** `ubuntu-latest` next to `macos-latest`; gate the Things
  checks on `WTS_NO_THINGS=1`. It would have caught `shasum` and `unixepoch()`
  (SQLite 3.38) already.

## Known, small, and not yet done

From the correctness audit; none loses data, each is a wrong result on a path
you can hit.

- Reply mode and `ctrl-e` send text plus Enter to the session's *active* pane
  when the agent pane is unknown (AGENT `-`); in the default layout that pane is
  the editor. Refuse without a known agent pane, or target the pane whose
  `pane_current_command` is `claude`.
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
