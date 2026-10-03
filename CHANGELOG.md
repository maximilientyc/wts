# Changelog

## Unreleased

Schema 7, two new tables, created on the first command.

- **PR, CI and review state per session.** `wts pr --refresh [--json]
  [name...]` asks `gh` for each session's pull request (number, state, review
  decision, checks) and caches it in a `pr_state` table. The switcher shows a PR
  column — `#42 ✓`, `#42 ✗ci`, `#42 chg`, `#42 ...`, `closed`, `merged` — sorts
  merged sessions last, and its preview spells the PR out and, on a merged
  session, says what `ctrl-d` does. `gh` never runs from `wts ls`, the
  collector or the 2-second tick: only on `wts pr --refresh` and on the
  switcher's slow timer, every `WTS_PR_REFRESH` seconds (300, `0` for never),
  in the background and once for all open popups. The PR is the one Claude
  Code linked in the session's transcript when its head is the session's
  branch, else what `gh` finds for the branch.
- **`wts status --json` gains `pr`**: `null`, or `{number, state, review,
  checks, merged_at, url, refreshed_at}` (`state` is `open`, `closed` or
  `merged`; `review` `approved`, `changes_requested`, `review_required` or
  `null`; `checks` `pass`, `fail`, `pending` or `null`). The array is now also
  sorted with merged sessions last.
- **`merged` is right about squash merges, and about new branches.** It was
  `git branch --merged` alone: a PR merged by squash or rebase read `false` for
  good, and a session nothing was committed to yet read `true`. It is now the
  patch-id test `wts gc` tears down on, moved into `wts-db.zsh` and shared,
  with its verdict cached per pair of tips so that the 2-second tick stays a
  `rev-parse` per session.
- **`wts rm` deletes a squash-merged branch without `-f`**, which
  `git branch -d` refuses — `ctrl-d` on a merged row ended on "not merged (use
  -f)" with the branch left for gc — and archives the session as `squashed` or
  `merged` instead of `removed`.
- A one-line error from sqlite3 or tmuxinator was cut to its first character in
  three messages of `wts gc` and `wts doctor` (`⚠ registry not updated: d`).

## 1.6.0 — 2026-10-03

After upgrading: `wts setup claude --install` (a sixth hook, the read-only
permissions, the wts skill) and `wts setup tmux --install` (the snippet, now
between markers, replacing the one an older wts appended); `wts doctor` says
whether anything is left. Two changes of behaviour to know: `wts gc` now looks
only at the branches wts sessions had (`--all-branches` for the former scope),
and a creation without a terminal on stdin no longer attaches. Schema 5, two
new tables, imported on the first command.

wts reads what it already writes: the archive, the briefs and the notes were
written at every teardown and read by almost nothing.

- **Previous attempts, in the task's context.** `.wts/context.md`, the
  `SessionStart` hook and the switcher's task preview now carry the last three
  archived sessions of the task: outcome, PR, and the retrospective's
  `delivered`, `resisted`, `resolved` and `abandoned` lines. A retry starts
  where the last attempt stopped instead of rediscovering it. `wts task show`
  prints every attempt with all four lines; it used to print `delivered` alone.
- **The session preview shows its brief and notes.** Under the state line, the
  cached `done:` / `next:` of `wts brief` with its age, and the last two notes
  the session's agent left. Database reads only, no model call.
- **`wts gc --all`** runs the same collection once per repository that has a
  registered session, each from its main worktree, from anywhere.
- **`wts ls` gets a REPO column** when sessions span more than one repository.

The command surface: what a command does when it is mistyped, asked for help,
or fails, and what wts says about its own setup.

- **`wts doctor`** checks what wts needs (git, tmux 3.2+, tmuxinator, sqlite3
  3.38+, jq, perl), what it can use (which switcher features an older fzf turns
  off, whether `claude agents --json` answers, gh, the banner, Things from its
  cached verdict only), and whether the tmux snippet and the five Claude hooks
  are installed and come from this install. Exit 1 when something required is
  missing. A creation now checks for tmux and tmuxinator before it makes the
  branch and the worktree, instead of failing on the last line.
- **A typo is not a session.** `wts lsit` alone, with no session or branch of
  that name, says "did you mean `wts ls`?", exits 2 and creates nothing. A
  second word (`wts lsit default`) says the name is meant.
- **`--help` for every command**: `wts <command> --help` and `wts help
  <command>` print that command's usage. `wts new --help` started a session
  named `--help`; `wts rm --help` tried to remove one.
- **Exit codes that mean something.** `wts restore` exits 1 when a session could
  not come back, or a name matches none; `wts task unlink` on a name that is no
  session exits 1; `wts ls --json` refuses the argument (exit 2) instead of
  printing the table.
- **Failures say why.** tmuxinator's own first line ("Failed to parse config
  file…") after "tmuxinator failed to start", in `restore` and `new`; sqlite3's
  after "registry not updated"; wts-retro's after "not archived", in `rm` and
  `gc`. Under `C-b : wts`, a failing `wts` keeps its window open on the message,
  and `doctor`, `keys`, `doc`, `stop` and `pr` no longer wait for a fetch.
- **Ctrl-C while a phrase is being named** takes the name derived from the
  phrase and goes on, saying after how long; it used to abort the creation.
- **The SessionStart hook is shorter.** It lists the sessions of the same
  repository only (eight at most, their five latest notes, each brief with its
  age), caps a task's notes at twelve lines, and prints the directives about
  overlap only when such a session exists; alone on its repository an agent gets
  one line. "Leave a note anyway" is gone. `WTS_CONTEXT_QUIET=1` keeps only who
  the agent is and its task.
- **One word per action.** `ctrl-x` stops a session, in the popup's prompt and
  the README as in the CLI (they said "kill"). `wts doc forget` removes a
  document from the library (`wts doc rm` still works): `rm` is a session's
  teardown. A session serving a task is marked `@` in SUBJECT; `*` after NAME
  stays the current session.
- **gc collects what wts made.** By default it looks only at branches a session
  of the repository had (registry or archive) and husk folders named after one;
  the dry run counts the rest. `--all-branches` is the former scope. The dry run
  also says that `--apply` will ask Claude for N retrospectives, and `wts brief`
  says how many calls it is about to make, before making them.
- **`wts setup tmux --install`** writes the snippet between markers in
  `~/.tmux.conf` and replaces it on the next upgrade, an unmarked block from an
  older wts included; a status line moved below a theme is left there, not
  doubled. `wts setup tmux >> ~/.tmux.conf` appended a second block per upgrade.
- **Docs and completion caught up**: every variable in the configuration table
  (`WTS_RETRO_TIMEOUT`, `WTS_RETRO_JOBS`, `WTS_NO_THINGS`, `WTS_THINGS_DB`,
  `WTS_TASK_MAX_CHARS`, `WTS_DB`, `WTS_STATE_DIR`, `WTS_SWITCH_TASKS`,
  `WTS_ARCHIVE_TRANSCRIPT`, `WTS_NO_ARCHIVE`), every option in `wts help`, and
  completion for `--task`, `new --doc`, `task doc`, `task unlink` (a session),
  `gc --all-branches`, `retro --jobs` and `setup tmux --install`.

wts, from the agent's side: a Bash tool with no terminal and `$TMUX` set. An
agent working in a session was served well; an agent driving wts found nothing
built for it. Schema 5, two new tables, imported on the first command.

- **Never in the way.** Things is read from a terminal only: the hook told
  every agent to run `wts task show <id>`, `setup claude` allowed it, and its
  snapshot read Things — the privileged read (and macOS dialog) reserved for a
  command you type. `WTS_THINGS_FROM_SCRIPT=1` for a cron job. Without a
  terminal no picker opens and no question is asked: exit 2, and what to pass
  instead. A creation without a terminal never attaches (`--detach` says so
  explicitly): from an agent's pane it used to move your terminal.
- **JSON for every listing**, versioned: a creation's `--json` (detached, the
  session on stdout; an array for `wts new`), `task ls/show --json`, `doc
  ls/show --json`, `brief --cached [--json]` (the last summaries, no model
  call), `gc --json` (the dry run's plan), `doctor --json`.
- **`wts send`, `wts wait`, `wts tail`**: type into a session's agent, wait until
  it stops working (`--until`, `--timeout`, 90 s by default), read its last
  messages from its transcript. `send` types into the agent's own pane, which
  its hooks now record (`agent_panes`), and refuses when it is not known; the
  switcher's reply mode and `ctrl-e` follow the same rule instead of typing
  into the session's active pane (the editor of the default layout).
- **Real file overlap.** A sixth hook, `PostToolUse` on edits, records each
  file an agent edits (`touches`); the first time it edits one another session
  of the repository has edited, the tool result names that session. The
  SessionStart hook lists the files both have edited.
- **Notes as they are written.** At the start of each turn, the notes the
  repository's other agents left since the agent's last turn — five lines at
  most, nothing when there is nothing new.
- **A task link the agent can judge**: the hook says when and how the session
  was linked, and how to relink it.
- **The wts skill.** `wts setup claude --install` writes
  `~/.claude/skills/wts/SKILL.md`: what an agent loads when it needs wts —
  inside a session, or anywhere you ask your Claude about parallel work. The
  SessionStart hook shrinks to who the agent is, its task, its siblings and
  the overlap, and points to it. `--install` also allows the read-only verbs
  (`ls`, `task ls`, `doc ls`, `log`, `wait`, `tail`…), never `rm`, `gc`,
  `stop`, `send` or a creation. `wts doctor` checks all of it.
- **`wts gc` from inside a session** works on the repository: it took the
  session's worktree for the repository, as `--all` and `wts-fresh` did not.

## 1.5.2 — 2026-10-02

- **A task's preview in the switcher lists its sessions**: the live ones with
  their agent's state, then the finished ones with their outcome, PR and what
  they delivered (the last five; `wts task show` has the rest). The row only
  said `N session(s)`.

## 1.5.1 — 2026-09-29

- **A task stays in the switcher while a session serves it**, after the tasks
  still to start, with `N session(s)` in SUBJECT. It used to leave the list at
  its first session, and with it `enter` on the task: the popup had no way to
  start a second session on the same task.

## 1.5.0 — 2026-09-28

The attention loop closes. Until now the only way to learn that an agent was
waiting for you was to open the switcher (a poll every 2 s) or to press
`prefix+a`; wts had no clock for `blocked` and no idea what the question was.
The agent knows all of that and Claude Code says it through its hooks — so wts
listens. Schema 4, one new table, imported on the first command.

- **wts records the agent's own events.** `wts setup claude --install` now
  installs four more hooks, all on `wts-hook`: `UserPromptSubmit` (a turn
  starts), `Stop` (it ends), `Notification` (a permission, a question) and
  `SessionEnd`. Each writes a row to `agent_events`; outside a wts session the
  hook is silent. It never prints on stdout, since Claude Code would add a
  `UserPromptSubmit` hook's output to the conversation, and always exits 0,
  since a failing `Stop` hook would block the turn.
- **A bell and a banner when an agent needs you**, from the `Notification`
  and `Stop` hooks: the pane's own bell, so tmux flags the window, and a
  desktop banner naming the wts session ("wts: auth-form needs you — Bash: rm
  -rf dist"; "wts: auth-form is done — turn finished in 4m12s"). Skipped when
  the pane is already under your eyes: session attached, window active and,
  on macOS, a terminal in front. `WTS_NOTIFY=0` turns both off, `bell` or
  `banner` keeps one. With `terminal-notifier` (on PATH, or `WTS_NOTIFIER`)
  a click on the banner switches the tmux client to the session; otherwise
  macOS's own notification, or `notify-send`. If you had wired a notifier of
  your own on these events, this replaces it.
- **Since when, and waiting for what.** `wts status --json` gains
  `agent_since` (epoch of the event that put the agent in its state) and
  `agent_source` (`agents` or `events`); `agent_waiting_for` is filled from
  the notification when `claude agents` gives none. The list sorts the
  longest-waiting first within each state, `prefix+a` lands on the oldest
  question and says why in the status line ("wts: auth-form — blocked 4m:
  Bash: rm -rf dist"), and the switcher's preview opens on the same line.
- **A status-line segment.** `wts setup tmux` appends `wts-status --line` to
  `status-right`: "wts: 2 blocked · 1 idle", nothing when nobody needs you,
  refreshed every `status-interval`. No git in that pass.
- **State without `claude agents`.** When claude cannot be asked, or does not
  list the agent, the last event decides: working, idle, blocked — unless it is
  an end, or older than twelve hours. With it, its word is the state and the
  events only date it.
- **Restore resumes the agent's own conversation.** The hooks record the
  Claude session id, so `wts restore` pre-fills `claude --resume <id>` when
  that transcript still exists (`WTS_RESUME_ID` for layouts), rather than
  `--continue`, which takes the most recent conversation in the directory —
  not always the agent's.

## 1.4.1 — 2026-09-28

A safety release: every destructive path that could act on a session nobody
named now refuses, asks, or reads the registry instead of guessing. Found by a
review of the whole tool; the first five had the same shape — `wts rm` trusted
its input more than `wts stop` did.

- **`wts rm` finds the worktree through the registry**, not the current
  directory. `git rev-parse --show-toplevel` from inside a worktree names that
  worktree, so `rm` derived `<worktree>-worktrees/<name>`, found nothing,
  killed the tmux session anyway and dropped the registry row — the real
  worktree and its branch left behind, unlisted. The switcher's `ctrl-d` runs
  `rm` from wherever the popup opened, so this was one key away. A session of
  another repository went the same way. Only a name the registry never saw
  falls back to the repository at hand, and then to its main worktree.
- **Creating from a shell inside a worktree no longer nests worktrees.** The
  layout's shell window sits in the worktree; `wts foo` typed there created
  `<repo>-worktrees/<session>-worktrees/foo`, where gc never looks. The hop to
  the main worktree that `wts-fresh` had is in `wts` itself now.
- **A guessed name is confirmed, or refused.** The resolver matches substrings
  both ways, so `wts rm api-v2` with no such session landed on `api` — and
  `-f` force-removed it, with one line on stderr for all warning. An exact name
  goes through; a guess is shown and asked y/N; with no terminal to ask (the
  switcher, a script) it is refused. An empty name is refused everywhere, and
  `rm` of a name that is nothing at all exits 1 instead of 0.
- **`ctrl-d` asks first**, as `ctrl-x` did, and names the agent state it shows:
  the list re-sorts under the cursor every 2 s, so the row it fires on is not
  always the row aimed at. `rm` also checks the worktree is clean *before*
  killing the session: git refused a dirty worktree after the agent was gone,
  leaving it dead with its work half torn down. `rm` refuses the current
  session, like `stop` and gc.
- **An explicit name already used by another repository is refused.** The row
  is keyed on the name alone: `wts fix-tests` in repo B while A had one created
  B's worktree, overwrote A's registry row with B's paths, then attached to A's
  tmux session. Session names are global to the tmux server; the message
  suggests a prefixed one.
- **The hook names the task it tells the agent to look at.** It printed
  `wts task show` with no id, which resolves the task through the Things picker
  — a read of Things' container and an fzf with no terminal — and an agent may
  not open Things. `wts task show` with no id inside a session now shows that
  session's task, as `note`, `edit` and `doc` already did.
- **`wts setup claude --install` adds the permissions the hook needs**:
  `Bash(wts db:*)`, `wts task note`, `wts task show`, `wts status`. Without
  them the first thing every agent did was wait, blocked, for you to allow
  `wts db notes --all`. Appended once each, in your own order.
- **Fixed: under `fr_FR` (any comma-decimal locale) the switcher's refresher
  ran with no delay** on a repository where a pass outlasts the interval:
  `printf '%.1f'` wrote `12,3`, `sleep 12,3` failed at once, and its error was
  written onto the popup. Formatted under `LC_ALL=C`.
- **Fixed: `wts ls` forgot a worktree removed by hand without a trace.** A
  registry row whose folder is gone is archived first (outcome `unknown`, the
  facts the registry holds), then dropped: `wts log` now knows the work
  existed.
- **Fixed: paths compared as strings.** A `WTS_WORKTREES_BASE` with a trailing
  slash, or through a symlink, stored a path the collectors never matched
  against git's canonical one: the agent showed `-`, and gc's busy guard did
  not know it was there. The base is canonicalized at creation, and every
  compare accepts both spellings.

## 1.4.0 — 2026-09-28

A task had a beginning and no end. One created in wts (`ctrl-t`, `wts task new`)
stayed open for good: nothing refreshed it and no verb closed it, so it sat among
the tasks to start — and came back there each time a session on it was removed,
merged work included.

- **`wts task done [<id>]` closes a local task.** It leaves the switcher's task
  rows for good; its notes, documents and archived sessions stay, so `wts task
  ls` and `wts log` still show the work. With no id, the task of the session you
  are in.
- **`ctrl-d` on a task row does the same**, after a y/N prompt. On a session row
  it is still `wts rm`.
- **A Things task is refused, not closed**: it is completed in Things, and leaves
  the list at the next `wts task ls`. wts never writes to Things, and a status
  set here would be overwritten by the next refresh anyway.

## 1.3.2 — 2026-09-28

1.3.1 took the macOS privacy dialog off the switcher; this takes it off the rest.
The rule is now one read of Things per command, and none at all when there is
nothing there to read — each open of another app's container is a prompt, and
macOS does not always remember the answer.

- **A local task no longer opens Things.** `snapshot` went to the container for
  every id it was handed, including the `local:` ones that by definition have
  nothing there. `wts task show`, `wts task link` and `wts <name> --task` all
  asked, for an answer that is always empty — and most tasks are local ones,
  since that is what `ctrl-t` with a title creates.
- **Creating a task from the picker reads Things once, not twice.**
  `wts-things pick --json` hands back the whole task instead of its id alone, so
  the snapshot is taken from what the picker already read rather than from a
  second `show` on the very task the process was holding.
- **`wts task ls` reads Things once, not once per task.** It refreshed each
  snapshot with its own `show`; with three Things tasks on the list that was
  three dialogs for one `ls`.
- **Fixed: `wts task ls` leaked its own variables into the listing** — from the
  second task on, seven lines of `name=''`, `outcome=''` … between the tasks. A
  bare `local a b` re-run in a scope that already has them makes zsh *display*
  them; the declaration belongs outside the loop.

## 1.3.1 — 2026-09-28

- **Fixed: opening the switcher raised a macOS privacy dialog** — "iTerm would
  like to access data from other apps", on every single popup open. Reading
  Things' container is a privileged operation on macOS 15+, and the switcher
  asked `wts-things db` at startup — a real glob into that container, and a
  real SQLite open — only to decide how to word one footer line. The verdict of
  a probe is now cached in wts's own database under `kv['things.db']`, and the
  switcher and `wts keys` ask `wts-things available`, which reads that and
  nothing else. Only the commands that genuinely read Things (`wts task add`,
  `wts log`, `ctrl-t` on an empty title) still reach for it, and each one
  refreshes the cache. Until one of them has run, `ctrl-t` on an empty title
  still opens the Things picker — that key press is the probe — and the footer
  stays silent about Things rather than promising it.

## 1.3.0 — 2026-09-28

- **`ctrl-t` in the switcher creates a task.** It used to only pull one in from
  Things, and was not bound at all without Things: a task could be created only
  from a terminal (`wts task new`). Now the prompt becomes `new task>`, `enter`
  creates the task and puts the cursor on it; an empty title still opens the
  Things picker where there is one. The cursor is placed by `load` once the list
  is reloaded, because `pos()` chained after `reload-sync` runs on the old list.
- **`enter` on a task asks what to do with it** instead of starting a session at
  once on a name derived from the title: a new session from a prompt, a new
  session from a branch name (both through `wts-fresh`, both pre-filled), or
  attaching the task to an existing session. A second fzf in the same popup, not
  tmux's command-prompt, which raced the popup's teardown. `esc` goes back to the
  list.
- **Fixed: the switcher stopped refreshing as soon as a task row existed** — the
  list stayed on its skeleton, spinner turning. zsh's `read -d` changes the terminal's mode
  through the shell's own tty, whatever it reads from; run by fzf (a reload or a
  preview, in a process group of its own) that is a terminal change from the
  background — SIGTTOU, and the process stops for good. The reads on those paths
  split the rows with parameter flags instead.

## 1.2.0 — 2026-09-28

The task stops being a label and becomes the place context lives — and it reaches
the switcher, which is the view that gets used. Schema 3, imported automatically
on the first command; nothing existing changes shape or behaviour.

- **The switcher lists the open tasks that have no session**, under the sessions:
  `task` in the AGENT column, `N ctx` in DELTA (documents + links + notes), and
  the task itself as the preview. `enter` on one **starts a session on it**: the
  name is derived from the title with `WTS_NO_LLM=1` (the popup must not call the
  model), and the window it opens runs `wts-fresh` — exactly what the `wts`
  command-alias does for `prefix+g` — so the branch is still cut from a freshly
  fetched `origin/<default>` and creation still refuses outside a repository.
  `WTS_SWITCH_TASKS=<n>` caps the list (10), `0` hides it.

  It does *not* pre-fill tmux's command prompt, which was the first design.
  `command-prompt` puts interactive state on the client, and the switcher runs
  inside the popup's own process: the prompt raced the popup's teardown and tmux
  discarded it. Measured on tmux 3.7, from identical code — the prompt appeared on
  the first `enter` of a take and was gone on the second, on the same server.
  Deferring it through `run-shell -b` did not fix it, and `send-keys` into the
  pane behind the popup is worse: in a wts session that pane is usually nvim or
  the agent, and the line would be typed into a file. The cost is that the name
  and layout are no longer editable before it starts; `prefix+g` is still there
  for a creation you want to compose by hand.
- **`tab` on a task is note mode.** The same machinery that replies to an agent:
  the prompt becomes `note on <task>>`, and `enter` appends the line to the task's
  notes instead of sending it to a pane there is none of. What was missing was
  never the pane — it was a place to type prose without leaving the popup, which
  this already was.
- **`ctrl-e` on a task attaches the document to the task**, not to a session, so
  every later attempt at it inherits the document. **`ctrl-t` pulls a task in from
  Things** (`wts task add`) — which is what fills the list, since the switcher only
  ever reads its own database: one query, no Things, no git, no model, because it
  runs every 2 s.
- **`wts task note`, `wts task edit`, `wts task doc` and `wts task add`**: free text
  and context documents kept ON a task, all defaulting to the task of the session
  you are in. They live in two new tables (`task_notes`, `task_docs`) and not in
  two more columns on `tasks`, for two independent reasons: `snapshot()`
  overwrites every column it reads from Things, so a column would be wiped by the
  next `wts task ls`; and `db_init` only ever runs `CREATE TABLE IF NOT EXISTS`, so
  a new table migrates itself while a new column would silently never appear.
- **`--task` now actually hands the task's context over**, through four channels
  because each fails differently: the **title becomes the agent's opening prompt**
  when no phrase was typed (`wts fix-audit --task <id>` used to start the agent on
  nothing at all); the task's **documents** are attached like `--doc` ones;
  `.wts/context.md` **opens with the task** — title, status, notes, links — which is
  the only channel read before the agent's first turn; and the `SessionStart` hook
  **repeats** it, the only one that comes back after `/clear`, `/compact` or a
  resume. The hook also prints the task's links at last: they had been selected
  and thrown away since the task layer landed.
- **Fixed: `ctrl-d` in the switcher could offer to delete any session.** It ran
  `wts rm {3}` straight from the bind, and `wts rm ''` reaches
  `registry_resolve_name`, whose substring match (`[[ "$k" == *""* ]]`) matches
  *every* session and opens a picker over all of them. Only the header row
  produced an empty `{3}` and `--header-lines` makes it unselectable, so it was
  unreachable — until a task row, which is selectable. It goes through a guarded
  `--rm` verb now, like `--kill`, `--pr` and `--doc`.
- **Fixed: `wts new --task <id>` created sessions linked to nothing.**
  `strip_doc_args` has read `WTS_TASK_ARG` since the task layer landed, and
  nothing ever set it. A bare `--task` is resolved once in the parent, so the
  Things picker does not open once per session of the batch.
- **Fixed: `wts status --fzf` and `--table` printed `[]` on an empty registry.**
  Only `--json` has a representation of "nothing"; the switcher read that line as
  a session named `[]`. Invisible while the registry always had a session in it, a
  junk row the moment it does not — a fresh install, or tasks queued and no
  session yet.
- **Fixed: `wts --task <id>` reported "unknown option '--task'".** An option
  cannot come first — the stray-option guard runs before any parsing — but that
  message sends you looking for a typo. `--doc` and `--task` now say that the name
  comes first.

## 1.1.0 — 2026-09-28

Teardown stops destroying the evidence. Schema 2, imported automatically on the
first command; nothing existing changes shape or behaviour.

- **`wts gc --apply` and `wts rm` now archive what they tear down**, into a new
  `archive` table that nothing ever deletes. They used to do the opposite:
  `registry_del` and gc's closing transaction dropped the session row, its brief
  and its notes, so the moment a piece of work became tellable was the moment wts
  forgot it. Kept per finished session: the phrase it started from, the branch and
  its base, the outcome, the pull request, the commit subjects, the paths touched,
  the diffstat, the agents' notes and the last brief. The teardown SQL is
  otherwise unchanged — the archive only ever inserts, before the delete — so if
  capture fails, teardown proceeds exactly as before.
- **A four-line retrospective per finished session** (`delivered` / `resisted` /
  `resolved` / `abandoned`), written by Haiku at `wts gc --apply` while the
  transcript still exists. Not a convenience: Claude Code deletes transcripts
  after 30 days by default (measured on the machine this was built on: 275
  transcripts, none older than that), while a performance review looks six months
  back. `resisted` and `resolved` are read mostly from the author's own
  corrections to the agent, the only place friction is recorded. A partial answer
  is kept rather than rejected — the opposite of `wts brief`'s rule, because the
  source will be gone. `wts retro` writes the ones gc could not; `gc --no-retro`
  and `WTS_NO_LLM=1` skip the call, and the facts are archived either way.
- **`wts log`**: the whole window as one JSON document — archived sessions, live
  ones, and completed Things 3 tasks that never had a worktree, which is where
  meetings, mentoring and incidents live. `--since`/`--until` take an ISO date or
  a sqlite modifier (`-6 months`), `--brief` drops the bulk, `--no-notes` drops
  the free text. The payload carries `version: 1`; its `outcome` vocabulary
  (`merged squashed remote-deleted removed abandoned in-progress unknown`) is now
  a public contract, listed in CLAUDE.md beside `agent_state`.
- **`wts task`**: the durable unit above a session. One task, one to N sessions,
  so `wts log` can show three attempts over five weeks instead of three unrelated
  branches. `wts task link` attaches a session, `--task` links at creation,
  `wts task ls` is the grouped view. Read-only towards Things 3: its database is
  opened with `-readonly`, there is no write verb, and the schema is checked
  before use so a Things upgrade degrades with a reason instead of answering
  something subtly wrong. `wts task new` covers a machine without Things.
- **The links in a task's notes become context documents.** `--task` reads the
  URLs out of the task and attaches them as pointers, so the agent opens on the
  Notion page or the Slack thread the author already curated instead of being
  told to go and find it. Pointers rather than fetches on purpose: one to three
  links per task, a sonnet fetch capped at 90 s each, and a private page is
  exactly what the sandboxed fetch cannot read and the agent in the pane can.
- **A `*` in the SUBJECT column** marks a session that serves a task. Only a
  sign, and the task title only when nothing else is known: `wts ls` and the
  switcher stay one flat list, because that is the view that has to stay
  scannable. `wts status --json` gains `task` and `task_title`.
- **The transcript is kept**, gzipped, under `~/.local/state/wts/transcripts/`
  (about 2–5 MB per semester), so `wts log` can report whether the raw
  conversation is still readable — `transcript.available`, tested at export time.
  `WTS_ARCHIVE_TRANSCRIPT=0` turns the copy off, `WTS_NO_ARCHIVE=1` the capture.
- **Fixed: the first command in a fresh state directory exited 1 without
  printing anything.** `db_init` ends by cleaning up the pre-1.0 cache
  directories, and `rmdir` on a directory that never existed returns 1 — which
  `set -e` in `bin/wts` turned into an abort, after the schema had been created.
  A new install's very first `wts ls` said nothing at all.
- **Fixed: two installed wts versions fought over the schema version.** The check
  compared for equality, so an older binary wrote its own, lower version back and
  the two migrated against each other forever, one write transaction per process
  each way. It is `>=` now; every change to this schema is additive.
- Privacy is documented next to the command it concerns: `wts log` prints
  prompts, commit subjects, file paths, agent notes and your task notes on
  stdout, and it is the most sensitive thing wts produces.

## 1.0.1 — 2026-09-28

- **The `SessionStart` hook now asks for something.** `wts-context` listed the
  other sessions and the `wts db` commands, and an agent read it as ambient
  noise: awareness without an action. Its output ends with a MANDATORY block
  naming the two moments that matter — check the siblings and `wts db notes
  --all` before touching a file, migration, schema or API; `wts db set` right
  after a change another session may depend on. No extra work at session start:
  same single read of the database, no git status, no model call.

## 1.0.0 — 2026-09-28

Major version: the state moves from files to a SQLite database. The import is
automatic; see [Upgrading to 1.0](README.md#upgrading-to-10) for the steps and
the rollback.

- **All state in one SQLite database**, `${XDG_STATE_HOME:-~/.local/state}/wts/wts.db`:
  the session registry (was `sessions.json`), the `wts brief` cache (was `brief/`),
  the stale guard's pane hashes (was `panehash/`) and the fetched documents (was
  `docs/`). The registry was one JSON file rewritten whole with `jq > tmp && mv` by
  `bin/wts`, `wts gc` and `wts doc use`: two of them at once lost one update, and a
  killed run left `sessions.json.tmp.<pid>` behind. The database runs in WAL mode,
  every connection waits up to 5 s for a writer instead of failing, and a
  prune is one `DELETE` instead of one file rewrite per stale entry.
- **Automatic import.** The first command after the upgrade imports
  `sessions.json` and the document cache, renames the old file
  `sessions.json.migrated` and says so once. The brief cache and pane hashes are
  dropped (rebuilt on first use).
- **Agents know about each other.** `wts setup claude [--install]` adds a Claude
  Code `SessionStart` hook, `wts-context`: in a wts session, every agent starts
  (and restarts after `/clear` or `/compact`) with its session, the other sessions
  — same repository first, with their task and last brief — the latest notes the
  agents left, and how to query the rest. Silent outside a wts session; reads the
  database only, ~0.1 s.
- **`wts db`**: `sql` (read-only, sqlite3 safe mode), `schema`, `path`, and
  `notes`/`get`/`set`/`del` for the one table agents may write: notes keyed by
  the session the command runs in (found from `$TMUX_PANE`, else the worktree).
  `wts rm` and `wts gc` drop the notes and brief of the sessions they remove.
- **sqlite3 is now required** for the registry (macOS ships it). Without it, wts
  degrades as it did without jq: sessions are created, nothing is registered.
- Unchanged: `wts status --json` (keys and values), the library in
  `~/.config/wts/docs.json`, the layouts.
- Rollback: reinstall 0.4.3 and rename `sessions.json.migrated` back; sessions
  created since are missing from it.

## 0.4.3 — 2026-09-24

- **A fetch that fails says why, and the run stays useful.** `wts gc` ran its fetch
  with `2>/dev/null`, so `Remote: fetch failed — analysis on local state` was
  everything a broken fetch ever said, whatever had broken. That hid the one failure
  that costs the most: `--prune` builds a *single* ref transaction for every deletion
  it has to make, so one ref git cannot lock loses the whole fetch — `origin/<base>`
  included — and every category then compares against a base days old and proposes
  nothing. gc now prints git's first lines verbatim, retries without `--prune` (each
  update its own transaction, so the base does come back fresh) and says precisely
  what is left degraded: only the `[gone]` detection, hence cat. 4. And it names the
  cause when it is the one behind `cannot lock ref`: two remote-tracking refs
  differing only by case — `origin/rm/x` and `origin/RM/x` — are **one path** on a
  case-insensitive filesystem, which is most macOS checkouts. Found on a repository
  where 4 such pairs among 13,901 refs had been blocking all 11,564 prunes for days;
  `git fetch` alone worked, so nothing pointed at it. The repair gc prints is one
  `git update-ref -d` per ref, because two in a transaction collide all over again.
- Fixed on the way: the stderr capture used `mktemp -t <prefix>`, which is BSD-only.
  With Homebrew's coreutils ahead of it in `PATH` that is "too few X's in template",
  and the capture fell back to `/dev/null` — the very bug being fixed.

## 0.4.2 — 2026-09-20

- **The document picker shows the whole row.** Now that the picker opens (0.4.1),
  what it displays is wrong: `--with-nth=1,2,3` was meant to pick the slug, title
  and kind columns, but `doc_table` aligns those with `printf` padding and fzf's
  default delimiter is a run of whitespace — so the three fields were the slug and
  the first *two words* of the title. `The product spec` read `The product`, and
  the kind and age columns never showed at all. The flag is gone: the row is
  already a table, and the picker now prints the one `wts doc ls` does.

## 0.4.1 — 2026-09-20

- **The document picker actually opens.** A bare `--doc`, `wts doc use` without a
  slug and the switcher's `ctrl-e` all advertise an fzf picker over the library;
  none of them ever showed one. The picker was gated on `[[ -t 0 && -t 1 ]]`, and
  `-t 1` cannot be true: the picker answers with a slug on stdout and every caller
  reads it from a command substitution, so stdout is a pipe even in front of a real
  terminal. `ctrl-e` was the worst hit — it goes through `wts doc use ""`, one more
  command substitution, inside fzf's own `execute` — and the numbered fallback it
  landed on prints to the screen `execute` had just handed over. The test is now
  `[[ -t 0 && -t 2 ]]`: stdin and stderr are the terminal on all of those paths,
  and fzf draws on `/dev/tty`, not on the captured stdout. The numbered list stays
  for a run with no terminal or no fzf, where it was always the right answer.

## 0.4.0 — 2026-09-20

- **Naming falls back to the local name far less often.** A naming call answers in
  3 to 16 seconds (measured over a dozen calls on this machine), and it was capped
  at 15: two runs in five were killed mid-answer, the phrase was named locally, and
  nothing said the model had been called at all — the worktree this was found in was
  itself named that way. `WTS_NAME_TIMEOUT` now defaults to 30 seconds.
- **A call that fails says why.** `wts-name` and `wts brief` sent the model call's
  stderr to `/dev/null`, so a missing `claude`, an expired login, a corporate proxy
  and a timeout all read `Claude unavailable or no answer`. The warning now carries
  the timeout it hit, the status `claude` exited with, or the line `claude` wrote
  itself; `wts brief` prints the same reason above the raw facts it falls back to.
- **A model id `claude` does not recognize can no longer become a branch name.** It
  is not a failure it exits on: it answers in prose with status 0, and *"There's an
  issue with the selected model…"* kebab-cased and cut to 40 characters looks like a
  perfectly good branch name. An answer longer than six words is now refused, and
  the `[claude-code:unrecognized_model]` line written on stderr is what the warning
  shows. Behind Amazon Bedrock or Google Vertex AI, where the `haiku` alias need not
  resolve, that is the difference between a puzzling name and a one-line diagnosis
  (set `WTS_MODEL` to the id your platform accepts).
- **`wts doc`: the context document you keep pasting into every agent, attached in
  one word.** A spec in Notion, an architecture page, a file of conventions on
  disk — the link was found again, the page waited for and the prompt rewritten at
  every new worktree. `wts doc add <url|path>` puts a document in a small library,
  fetched once and cached, and `wts <name> "<phrase>" --doc <slug>` attaches it:
  wts writes `<worktree>/.wts/context.md` and the Claude pane starts on
  `claude "Read @.wts/context.md first, …"`. Nothing is attached unless asked —
  there is no per-repository pinning on purpose, since several projects run at once
  and the document that matters to one worktree is noise in the next. `--doc` is
  repeatable, takes a slug, a URL or a path, and a bare `--doc` at the end of the
  line opens a picker. Layouts get the path in `WTS_DOC`.
- **The fetch uses whatever *this* machine can read.** A URL is fetched by a
  headless `claude -p` started with the machine's own MCP configuration, and the
  model picks the tool that can reach it: nothing about a provider is hardcoded,
  because the same page sits behind a Notion connector on one machine and behind a
  gateway with entirely different tool names on another. The allow list is built
  per server from `claude mcp list` and cached for a day (the CLI refuses a bare
  `mcp__*` wildcard in an allow rule), every write-shaped tool is denied, and
  `WTS_DOC_TOOLS` pins it by hand. When nothing can read the document it degrades
  to a **pointer**: the context file carries the URL and asks the agent to fetch it
  itself, which it usually can — it has the full set of connectors the headless
  call does not. A local file never calls the model at all.
- **`wts doc use <slug> [session]` attaches to a session already running**, and
  sends the reference into the agent's pane so it picks the document up without
  being restarted. **`ctrl-e`** in the switcher does the same on the highlighted
  row, picker included; it is unbound while replying, where it is an end-of-line
  reflex. `wts-switch --send` is now the single place that knows how to type into
  an agent's pane.
- The attached documents are recorded in the registry, so `wts restore` re-exports
  `WTS_DOC` and rebuilds a context file that disappeared — from the cache, never
  from the network: a restore is not an explicit attach.
- `.wts/` carries its own `.gitignore` containing `*` rather than an entry in
  `info/exclude`, which git shares between **every** worktree and the main checkout
  and which would have outlived `wts rm`. The worktree therefore stays clean in
  `git status`, which is what keeps `wts gc` able to tear it down and `wts ls` from
  showing it dirty forever. `wts rm` and `wts gc` take the folder away before
  `git worktree remove`, which leaves git-ignored files behind and would have made
  a husk out of every session that ever had a document.
- A URL fetched through `WebFetch` comes back as the model's rendering of the page,
  not the page: that tool summarizes whatever it reads, whatever it is asked. An
  MCP connector returns it verbatim. `wts doc show <slug>` is there to check.

## 0.3.1 — 2026-09-20

- **`ctrl-o` in the switcher opens the session's pull request on GitHub.** Reaching
  the PR of a session meant switching to it, reading the branch and opening GitHub
  by hand. The key runs the new `wts pr [name]` (the current session when run inside
  one), which is `gh pr view <branch> --web` in the session's repository: it finds
  the PR by head branch, merged or closed ones included, on a GitHub Enterprise
  remote too. Without a PR the popup prints why and waits for a key, like `ctrl-x`.
  `gh` is optional: without it the key is not bound, and the footer and `wts keys`
  do not list it.

## 0.3.0 — 2026-09-19

Measured on a generated 150k-file repository with 8 sessions and 3000 local branches (`make bench`; the numbers, the method and what was found are in `docs/big-repo-analysis.md`).

- **The switcher fills on a large repository.** The poller pushed a `reload-sync` every 2 s and fzf drops the pass in flight when the next arrives, so wherever a collector pass took longer than the interval (12 s here) the AGENT and DELTA columns showed `-` forever, behind a spinner that never stopped. The poller now skips its tick while a pass is running (only the preview refreshes) and waits at least as long as the last pass took before the next one. The first fill after the skeleton is a pass without git (agent states and tmux liveness, tens of milliseconds); the first refresh brings the git columns.
- **`prefix+a` no longer runs git.** It only needs agent states and tmux liveness, and paid the full collector for them: 12 s on the large repository, 0.1 s now (`wts-status --no-git`).
- **The collector's per-repository caches actually cache.** `branch --merged`, the base branch and the base ref were memoized in associative arrays but called inside `$(…)`, so the memo was written in a subshell and lost: `git branch --merged` over 3000 refs ran once per session (0.15–0.7 s each) instead of once per pass, a third of the tick. The smoke test now counts it. The agent record is read with one `jq` instead of five per session.
- **`wts gc` hashes the base once.** `git cherry` computed a patch-id for every base commit since the merge-base again for each local branch: 0.3 s per branch, 15 minutes for 3000 branches, with nothing on screen. The base's recent commits are hashed once, each branch's own commits are looked up in that set, and branches already merged by ancestry skip the step. Same rule (squash and rebase included), same output. `lsof` runs with `-n -P` (3x faster per lock candidate), and a fetch or a long classification says so on stderr.
- **`wts brief <name>` collects that session only.** It ran the full collector over every registered session first (13 s for one session on the large repository). The transcript is read once for its three records instead of three times, and the uncommitted `diff --shortstat` that the summary never used is gone.
- **`wts setup git`** prints the two repository settings (`core.fsmonitor`, `core.untrackedCache`) that take `git status` from 0.5 s to 0.04 s per 150k-file worktree and `wts ls` from 12 s to 2.6 s with 8 sessions. `wts ls` suggests it once on stderr when a pass takes more than 3 s in a repository without them. Applying them is left to the user: they are repository-wide and start a daemon per worktree.
- **Where the tool waited in silence, it now says so**: the `ls-remote` that checks origin for a new branch name (now capped at 5 s, like the uniqueness sweep; a timeout means "new branch", as a failure already did), the removal of a worktree in `wts rm`, the fetch in `wts-fresh` (no longer `--quiet`: git's progress is the feedback) and in `wts gc`.
- `test/bench-big.zsh` (`make bench`) generates that repository and times every command, with process counts; `docs/big-repo-analysis.md` is the analysis it produced.

## 0.2.1 — 2026-09-19

- **The switcher's keys are written under its list.** `prefix+s` had seven bindings and showed none of them: `tab`, `ctrl-x`, `ctrl-d`, `ctrl-f`/`ctrl-b`, `ctrl-r` were documented in the README and in a comment at the top of `wts-switch`, which is exactly where nobody looks while a popup is open. The popup now carries a footer: one line sized to the list (`enter switch · tab reply · ^x stop · ^d rm · …`), which drops its rarest keys rather than being cut mid-word on a narrow popup, and **`?`** unfolds the full table — the tmux bindings (`prefix+s`, `prefix+a`, `prefix+g`, `prefix+:`) included, since those cannot be pressed from inside the popup and are the first to be forgotten. The prefix shown is the one the running server reports, not an assumed `C-b`. In reply mode the footer says what `enter` and `esc` do *there*, and `?` is typed into the reply instead of opening the list; while the list is being filtered, `?` goes into the query too (the AGENT column has `stuck?` in it). Needs fzf 0.65 (`--footer`); older versions keep the popup exactly as it was, and are never handed a `change-footer` they would exit on.
- **`wts keys`** prints the same table in a terminal, for when the popup is not open — or not open yet. The footer and the command render from one helper (`libexec/wts/wts-keys`), so they cannot drift apart.

## 0.2.0 — 2026-09-19

- The switcher's list (`prefix+s`) is laid out for the width it actually has. Columns were padded to 22/10/30/14 characters and never cut, so a session name over 22 characters or a `feature/<slug>` branch over 30 pushed its whole row to the right, and the fixed part alone was 80 columns wide when the list pane had 50 to 65: DELTA, SUBJECT and the ` *` mark of the current session were never on screen. The session and branch columns now take the width of their longest value, capped so every column stays visible, every cell too long for its column ends in `…`, and every row is exactly as wide as the list. `*` moved next to the session name. The header re-lays out with the rows (`--header-lines=1`), and the preview takes half the popup instead of 60%.
- The switcher preview is **as wide as the agent's pane**, up to the half of the popup it starts with. The preview is a raw `capture-pane`, text at the pane's width: with the editor as the main pane (`main-vertical` at 75%), the agent's pane is 56 columns on a 223-column terminal and a 60% window was 110, so half of it was blank while the list had 76 columns for the 130 it needs to show the subject. The window now follows the highlighted session's pane (`focus` → `transform` → `change-preview-window`, fzf 0.46 or newer; older versions keep the half-width window). The list is laid out for the other half, so a pane wider than that is truncated on the right rather than pushed into the list.
- **The switcher answers an agent without leaving the popup.** `tab` pins the highlighted session and turns the query line into an input for it (`reply to <session>>`); `enter` sends the line to the agent's pane with `send-keys`, an empty line sends a bare Enter, and the 2 s refresh shows the agent's reaction in the preview. `esc` or `tab` brings the list back. Until now answering a permission prompt or an `AskUserQuestion` meant switching to the session and reopening the switcher afterwards, paying the collection again. The preview is a `capture-pane` snapshot, not a terminal, which is why the input is the query line and not a cursor in the pane. The reply is pinned on entry rather than read off the cursor: the list re-sorts by urgency every 2 s, and a reply retargeted by a reorder would type into the wrong agent. `ctrl-d` and `ctrl-x` are disabled in reply mode so a delete-char reflex cannot remove or stop a session. Needs fzf 0.45 (`transform`); older versions keep the previous switcher unchanged.
- **`wts stop <name>`** kills the tmux session and nothing else: the worktree, the branch and the registry entry stay, so `wts restore <name>` brings the session back, and `wts rm` remains the full teardown. Typo-tolerant like `rm`, it works from any directory (no git repository needed), on sessions wts never registered too, and never on the current session. In the switcher (`prefix+s`), **`ctrl-x`** runs it on the selected row after a y/N prompt: the popup stays open and the list reloads. Stopping an agent while keeping its worktree used to mean leaving the popup for `tmux kill-session`.
- The switcher shows **`stopped`** in the AGENT column for a registered session whose tmux session is gone. It showed `-`, so a session stopped from the popup looked exactly as before, and a leftover `claude agents` record for that worktree could even keep it at `working`. `wts status --json` is unchanged.

## 0.1.3 — 2026-09-17

- **`git add` in a worktree no longer fails with `Unable to create '.git/worktrees/<session>/index.lock': File exists`.** `git status` takes that lock before it scans and holds it until it has written the refreshed index back, and the collector statuses every registered worktree — on every `wts ls`, every switcher refresh (every 2 s while the popup is open) and every `prefix+a`. So it raced the agent's own `git add`, and a pass killed mid-scan left a zero-byte lock behind that broke **every** write in that worktree until someone deleted it by hand, inside `.git`. On the repository that motivated this, 7 worktrees out of 7 held one, the oldest a day old. `wts ls`, `wts status`, the switcher, `wts brief` and `wts gc` now run their status and diff with optional locks off: the refresh stays in memory, no lock file is ever created, and `git status` on a 95k-file repository still costs ~0.1 s because fsmonitor keeps answering. `wts` was also taking the **main** repository's index lock before `wts` (`prefix+g`) fast-forwards the local base, which could turn a fast-forward that git would have performed into the misleading "not fast-forwarded (diverged, or git operation in progress)".
- `wts gc` reports and, with `--apply`, removes stale `index.lock` files — including those left by something other than wts (an interrupted agent, a git UI in a torn-down pane). A lock is only ever touched once it is empty, older than `WTS_LOCK_STALE_AFTER` (5 min) and held by no live process: deleting a lock somebody owns would corrupt their index.

## 0.1.2 — 2026-09-17

- The switcher popup (`prefix+s`) opens **immediately**. It is drawn on a registry-only list — sessions, branches and subjects, no git and no agent call — and fzf swaps in the collected list as soon as it is ready. `prefix+s` used to show an empty frame for the whole collection pass: 1.7 s warm and about 5 s cold on a 95k-file repository. The agent and delta columns show `-` until the swap rather than a remembered value, so a stale agent state is never presented as current.
- `wts ls` and `wts status --json` measure the git counters (`added`, `removed`, `ahead`, `behind`, `merged`) against `origin/<base>` when it exists, as `wts gc` and `wts brief` already did. A branch cut from a freshly fetched base no longer reports the base's own history as its delta: a session with no commits of its own showed `+91727/-28066 ^333` and `merged: false` when the local base trailed the remote by three days. `base` keeps reporting the short branch name. On a large repository this also makes `wts ls` and the switcher **33% faster** (2.37 s → 1.60 s), because `git diff` walks the branch instead of everything the local base was missing.

## 0.1.1 — 2026-09-13

- An interactive Claude Code agent waiting for an answer (`status: waiting`) is shown as `blocked`: sorted first in `wts ls` and the switcher, picked by `prefix+a`, and left alone by `wts gc`. It used to be shown raw and ignored by all three.
- Starting a session no longer hangs when tmux is newer than tmuxinator knows: tmuxinator waited for Enter after an "unsupported tmux version" warning that `wts restore` and `wts new` hide. `--suppress-tmux-version-warning` is now always passed, and detached starts never read the terminal.

## 0.1.0 — 2026-09-13

First public release.

- `wts <name>` / `wts "<phrase>"`: git worktree + tmuxinator session, name proposed by Claude from a phrase.
- `wts ls`, `wts status --json`: registry, git delta and Claude Code agent state (with a stale guard).
- `wts brief`: "done / next" per session, summarized by Claude and cached.
- `wts restore`: replay registered sessions after a reboot, pre-filling `claude --continue`.
- `wts gc`: squash/rebase-aware cleanup; never touches brand-new branches, busy agents, dirty worktrees or folders outside `<repo>-worktrees/`.
- `wts layouts`, `wts setup tmux`, `wts help`, `wts version`.
- Layouts looked up in `~/.config/wts/layouts` first, then the built-in ones; branch prefix declared in the layout (`# wts: branch_prefix=feature/`).
- Homebrew-friendly install tree (`bin/`, `libexec/wts/`, `share/wts/`) and `make install`.
