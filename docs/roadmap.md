# Roadmap

What the review of 2026-09-28 left open, once 1.4.1 (the destructive verbs take
nothing on trust) and 1.5.0 (the agent's own hooks, a bell and a banner,
since-when) had shipped. Ordered by impact over size; S is an afternoon, M a
day or two. Each item names the code it builds on, so the estimate is checkable.
The rules of CLAUDE.md hold throughout: the model is never called from `ls`,
the switcher or a hook; `wts status --json` and `wts log` are contracts.

## 1. Read the data wts already writes

The archive, the briefs and the notes are written at every teardown and read by
almost nothing. Two small changes turn them into something you see daily.

- **Previous attempts, in the task's context. [S]** The schema promises "the
  second attempt starts where the first left off" (`wts-db.zsh`, the archive
  comment), but `task_context_md` and the SessionStart hook never read
  `archive`, and `wts task show` prints only `retro_delivered` — dropping
  `resisted`, `resolved` and `abandoned`, the three lines a retry needs. A
  "Previous attempts" block (outcome, PR, the three lines, capped at three
  attempts) in `task_context_md` reaches the switcher preview,
  `.wts/context.md` and the hook at once.
- **Briefs and notes in the switcher preview. [S]** The preview is the pane
  capture under one header line. Above it: the cached `done:` / `next:` of
  `wts brief` (no model call, the cache is keyed on HEAD and the transcript)
  and the last two notes the session's agent left. The `briefs` and `notes`
  tables are read by no switcher or status code today.
- **`gc --all`, and a REPO column. [S–M]** gc works on the repository you
  stand in (`wts-gc`, the `repo_root` block). Loop over
  `SELECT DISTINCT repo_root FROM sessions`, resolved through git's common
  directory as `wts-context` does, and run the per-repository gc unchanged.
  `wts ls` gets a REPO column or `--repo`.

## 2. The command surface

- **`wts doctor`. [S–M]** tmuxinator is discovered missing after the worktree
  exists (`bin/wts` execs it unchecked). Nothing verifies tmux ≥ 3.2
  (`display-popup`), the fzf 0.45 / 0.46 / 0.65 gates (the switcher degrades
  silently), that `claude agents --json` answers, or that the tmux snippet and
  the Claude hooks are installed and from this version. One command that
  checks all of it, and checks tmuxinator before `worktree add`.
- **A typo must not create a worktree. [S]** `wts lsit` creates a branch, a
  worktree and a session; nineteen subcommands shadow session names. A single
  word within edit distance 2 of a subcommand, with no such session or branch,
  gets "did you mean `wts ls`?" and exit 2 (`registry_resolve_name` already
  has the distance function).
- **`--help` per subcommand, and exit codes. [S]** `wts new --help` starts a
  session named `--help`; `wts rm --help` tries to remove one. `wts restore`
  with every session failed, `wts task unlink notasession` and `wts ls --json`
  (arguments dropped) exit 0. One `--help` guard in the dispatcher; non-zero
  when nothing matched.
- **Failures that hide their reason. [S]** `restore` and `new` send
  tmuxinator's stderr to `/dev/null` and print "tmuxinator failed to start";
  "not archived" and "registry not updated" drop it too. Print its first line.
- **Naming, while you wait. [S]** `wts "<phrase>"` from a shell blocks up to
  `WTS_NAME_TIMEOUT` (30 s) behind "→ naming…", and Ctrl-C aborts the whole
  creation. Trap INT to fall back to the local slug, show the elapsed time and
  the fallback name. (Through `wts-fresh` the wait already overlaps the fetch.)
- **The hook's MANDATORY block. [S]** `wts-context` prints its directives even
  under "No other wts session is registered"; "leave a note anyway — it costs
  nothing" invites notes every sibling then reads (ten are injected); Things
  notes are printed uncapped while wts notes are cut at 80; up to fifteen
  sessions are listed, other repositories included, which cannot collide; the
  "last brief" carries no age. Directives only when same-repository siblings
  exist, drop "anyway", cap, same repository only, brief age,
  `WTS_CONTEXT_QUIET=1`. About 1–2k tokens are re-injected at every start,
  `/clear`, `/compact` and resume.
- **One word per action. [S]** `rm` is teardown for a session and "forget" for
  a document; `ctrl-x` is "kill" in the README and its prompt, "stop" in the CLI
  and the footer; `*` after NAME is the current session, `*` before SUBJECT a
  session that serves a task.
- **Cost, said once. [S]** The gc dry run says "To archive: N session(s)" but
  not that `--apply` will ask Claude for N retrospectives; `brief` fans out four
  calls at a time. One line in the dry run, `--no-retro` named.
- **Docs and completion drift. [S]** The config table misses
  `WTS_RETRO_TIMEOUT`, `WTS_RETRO_JOBS`, `WTS_NO_THINGS` (the opt-out for a
  machine without Things, documented nowhere), `WTS_THINGS_DB`,
  `WTS_TASK_MAX_CHARS`, `WTS_DB`, `WTS_STATE_DIR`; `WTS_SWITCH_TASKS`,
  `WTS_ARCHIVE_TRANSCRIPT` and `WTS_NO_ARCHIVE` are prose-only; `WTS_MODEL` also
  drives retro. `wts help` and the README usage lack `--task` beside `--doc`,
  `log --task/--no-things`, `task ls --all`, `task note --clear`,
  `task doc --rm`, `retro --jobs`, `doc tools`. The README's hook example lacks
  the task section and the MANDATORY tail; its pass-through list for
  `C-b : wts` is stale. Completion: `wts task doc <TAB>` offers nothing
  (`_wts_docs` never calls `_describe`), `--task` is never offered, `new` lacks
  `--doc`, `task unlink` offers tasks but takes a session. `setup tmux >>
  ~/.tmux.conf` has no begin/end markers, so upgrades append a second block.
- **gc's scope: a decision.** gc classifies every local branch, not only wts's:
  a local `develop` fully contained in `main` is `branch -D`'d, a hand-made
  worktree on a merged branch is removed, and every `.git`-less folder under a
  shared `WTS_WORKTREES_BASE` is offered for `rm -rf`. The dry run lists it all
  and the README documents the categories, so this is a choice, not a bug: the
  recommendation is to default to branches wts knows (registry + archive) with
  `--all-branches` as the opt-in.

## 3. Then, by what you feel first

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
  the switcher marks them. This is what would make the MANDATORY block
  unnecessary.
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
- Under `C-b : wts`, `keys`, `doc`, `stop` and `pr` are not on `wts-fresh`'s
  pass-through list: they wait for a fetch, then the window closes before their
  output can be read. Any failure of `wts` under `wts-fresh` vanishes the same way.
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
