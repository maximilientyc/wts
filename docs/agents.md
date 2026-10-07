# Agents working together

Agents running in parallel on one repository can rework the same file, or
change an API another is building on. wts knows every session, so it shares that
knowledge with the agents themselves: what each agent is told when it starts,
the news it gets during its session, the database it can read and write notes
to, and how an agent drives wts the way you do from the switcher.

```
wts send <session> [--answer | --force] <text...>
wts wait <session>... [--until <state>,...] [--timeout <s>] [--json]
wts tail <session> [-n <k>] [--json]
wts db path | tables | schema [<table>] | row <table> <rowid> | browse [<table>]
wts db sql "<SELECT>" | notes [--all] | get | set | del
```

All of this needs the Claude Code integration: `wts setup claude --install`
adds the hooks, the permissions and the skill
([install.md](install.md#the-claude-code-integration)).

## Agents share state: `wts db`

### What every agent is told

In a wts session the `SessionStart` hook puts a short block at the top of the
agent's context, again after `/clear`, `/compact` and a resume:

```
# wts: you are in session `auth-form` (branch feature/auth-form, worktree …)

You are working on the task: **Validate the signup form**
Its notes (the author's own, verbatim):
  https://notion.so/Signup-spec-…
Previous attempts (newest first):
  - auth-form-try1 (abandoned, 2026-09-20)
    resisted: the email check raced the CSRF token refresh
Other sessions may serve the same task: `wts task show <id>` lists them.
Add to it as you learn: `wts task note "<what you found>"` — it outlives this session.
This session was linked at its creation, 2026-09-28. If the work has moved on to something else: `wts task link <id>`, or `wts task new "<title>"` then link it.

Other agents work in parallel on this repository, one per wts session (a git
worktree + a tmux session each). Their shared state is a SQLite database: …/wts.db

Sessions on this repository (newest first):
- rate-limit (feature/rate-limit): rate-limit the public API per key — brief, 2h ago: done: … / next: … — reach `rate-limit` with SendMessage
- csv-export (feature/csv-export): export users as csv

Latest notes they left:
- rate-limit/api-contract (3h ago): /login now answers 429 with Retry-After

Files you and another session have both edited:
- src/api/limits.ts (also: rate-limit)

If you edit a file one of them also edits, wts tells you then. When your change
affects them (a migration, a shared model, an API contract), leave one line:
  wts db set <key> "<one line>"
Everything else — their notes, live states, sending to or waiting for another
agent — is in the wts skill (or: wts help).
```

- **The task section** is there when the session serves a [task](tasks.md),
  with how and when the link was made: a session keeps the task it was created
  for while the work moves on, and the agent can tell. The task's own notes are
  cut at twelve lines.
- **The rest is about the sessions of the same repository**: another
  repository's cannot collide with this worktree, so they are not listed. Eight
  sessions at most, with their five latest notes and the files both sessions
  have edited.
- **"reach `<name>` with SendMessage"** ends the line of a sibling whose agent
  is running, when Claude Code's messages between sessions work on this
  machine ([below](#claude-codes-messages-between-sessions)). The name is the
  one Claude Code lists that agent under, read from its session file: the wts
  name when the layout passes `--name` (the built-in ones do), else one
  Claude Code derived. `csv-export` above has no agent running.
- An agent alone on its repository gets one line instead.
- `WTS_CONTEXT_QUIET=1` in the agent's environment keeps only the first line and
  the task's title.

All of this is re-read at every start, `/clear`, `/compact` and resume, so it
is kept to what can change what the agent does. The reference is the skill,
loaded when needed.

### The news during a session

Two hooks speak during the session, and only when there is something to say.
Both deliver the same news, each item once, to each agent.

- **At the start of a turn** (`UserPromptSubmit`):
  - the notes the same repository's other agents left or changed that this
    agent has not been told (five at most; `SessionStart` counts as telling);
  - the files it edited that a sibling has edited too since;
  - the sessions of the repository that finished, with how and the notes they
    left. A note is deleted with its author, often at the moment the change it
    announced lands:

  ```
  wts: session `rate-limit` finished (squashed, PR #37) — the notes it left: api-contract: /login now answers 429
  ```

- **After an edit** (`PostToolUse` on `Edit`, `Write`, `MultiEdit`,
  `NotebookEdit`): the same news, in the tool result, so a working agent hears
  of it before its turn is over. That includes the overlap the moment it
  happens: editing a file another session of the repository has edited says
  which session, on which branch, since when. The session that edited it first
  hears of it at its own next prompt or edit. When the edit was a subagent's
  (the payload carries `agent_id`), the line says so, since the agent reading
  it did not make that edit itself:

  ```
  wts: src/api.ts (by a subagent) was edited by session `rate-limit` too (branch rate-limit, first edited it 4m ago).
  ```

Every path edited through those tools is recorded in the `touches` table,
relative to the worktree. A file changed from the shell (`sed -i`, a formatter,
`git mv`) is not.

Anywhere else (a Claude started outside wts) the hooks print nothing. They read
and write the database only: no `git status`, no model call, about 0.1 s.

### What an agent (or you) can do

```
wts db tables [--json]                the tables, with their row and column counts
wts db schema [<table>]               the CREATE statements, of every table or of one
wts db row <table> <rowid> [--json]   one record, one field per line
wts db browse [<table>]               a table, then a row, picked in fzf (a terminal only)
wts db sql "<SELECT ...>" [--json]    read anything: sessions, briefs, notes, doc_cache...
wts db notes [--all] [--json]         this session's notes, or everyone's
wts db get <key>                      one note of this session
wts db set <key> <value|->            write a note ('-' reads stdin)
wts db del <key>                      remove a note
wts db path                           where the database is
```

`wts db help` prints the same list.

- **Reads cover every table.** `wts db sql` opens the database read-only and in
  sqlite3's safe mode (no `.shell`, no `ATTACH`, no `readfile`), so no query can
  damage the registry.
- **Writes cover only `notes`**, keyed by the session the command runs in:
  found from the tmux pane (`$TMUX_PANE`), else from the worktree containing the
  working directory.
- `--session <name>` reads another session's notes. Writing or deleting as
  another session takes a terminal (exit 2 without one): `wts db` runs without a
  permission prompt, and an agent leaves its own notes, not someone else's.
- `wts rm` and `wts gc` drop the notes of the sessions they remove, and what
  those sessions were told (`seen`). The notes stay readable in the archive
  (`wts log`), and the siblings are told the session finished.

### `wts db browse`

`wts db browse` is for you, in a terminal:

1. the tables with their counts and, in the preview, the schema of the one under
   the cursor;
2. `enter` lists its rows, newest first, each column cut to 24 characters, with
   the whole record in the preview;
3. `enter` again prints that record and quits; `esc` goes back to the tables.

Without a terminal it exits 2: an agent reads the same through `wts db tables`
and `wts db row`.

## Driving wts from an agent

An agent can do what you do in the switcher, from its Bash tool, which has no
terminal. Ask your Claude to "start three sessions on these tasks and tell me
when they are done", and with the skill installed it knows how:

```sh
wts "add a --json flag to wts brief" --json      # {name, branch, worktree, task, …}, detached
wts new -p default --json cors rate-limit        # several: an array
wts wait cors rate-limit --timeout 90            # 0 once neither is working, 1 on timeout
wts status --json | jq '.[] | {name, agent_state, agent_waiting_for}'
wts send cors --answer 1                         # answer the question it is blocked on
wts send cors "also cover the OPTIONS preflight" # a new prompt: to a working or idle agent only
wts tail cors -n 3 --json                        # what it said last, from its transcript
```

### Claude Code's messages between sessions

Claude Code 2.1.224 and later delivers messages between the sessions of one
machine, over a socket per session: `ListAgents` lists the others,
`SendMessage` sends to one by name, and `SendMessage` with `notify_when_idle`
asks for one notice when it next finishes a turn. Between two wts agents these
do what `wts send` and `wts wait` do, without the pane:

- **A message to a working agent** is read at its next tool call, in the same
  turn; one to an idle agent starts a turn. Either way it is never typed into
  a question the agent is blocked on.
- **The answer comes back as a message**, and the idle notice as a turn of
  its own, so the asking agent does not poll.

So the skill tells an agent to use them for a sibling `ListAgents` lists, and
`wts send` and `wts wait` otherwise: for an agent that is not listed (an older
Claude Code, a session whose agent has quit) and for anything that has no
`SendMessage` — you in a terminal, a script. `wts send` keeps typing into the
pane: no command line posts into another session's socket.

A message arrives as a prompt: the `UserPromptSubmit` hook fires for it, in an
idle agent and in a working one alike. `wts-hook` records it with `kind =
message` and the sender, so the events tell it from the author's own prompts,
and `wts brief` and the retrospective leave it out of what the author asked:

```
$ wts db sql "select event, kind, message from agent_events where kind = 'message'"
prompt|message|from rate-limit
```

`wts doctor` says whether it works here (Optional section):

| Line | Meaning |
|------|---------|
| `messages between sessions: available` | SendMessage reaches the other agents |
| `… needs claude >= 2.1.224` | this Claude Code is older |
| `… refused by crossSessionInbound` | a settings file sets it to `refuse`: nothing arrives |
| `… held by crossSessionInbound` | `hold`: each message waits for your approval in the receiving session |

The verdict (the version, the user and managed settings) is cached in the
`kv` table under `claude.messaging`, and computed again when Claude Code or
one of those settings files changes. A repository's own
`.claude/settings.json` can tighten the setting too, and is read every time.

Two things to know:

- **An agent in another permission mode** (one in auto mode, another asking
  for each permission) holds a message from it for its user's approval, in
  its own pane: that one is not delivered by itself.
- **A layout that does not pass `--name`** starts agents whose name is
  derived (`auth-form-3c`): send the name `ListAgents` shows, exactly. The
  context line already gives it.

### `wts send`

It types a line into the agent's own pane and submits it: the pane its hooks
recorded from `$TMUX_PANE`, or the one the collector matched. It refuses when it
does not know that pane. The switcher's reply mode and `ctrl-e` follow the same
rule.

It also looks at the agent first, because the caller cannot:

| Agent state           | `wts send` |
|-----------------------|------------|
| `working` or `idle`   | sends the prompt |
| `blocked`             | refused: it is asking a question, and what is typed there answers it. `--answer` sends it as the answer |
| quit                  | refused: its pane is a shell, where a sentence would run as a command |

`--force` types whatever the state.

### `wts wait`

- It returns once each session's agent is no longer working, or after
  `--timeout` (90 s by default, under the two minutes an agent's Bash tool gives
  a command): call it again to keep waiting.
- `--until blocked,idle` waits for those states only.
- Without `--until` it also returns on an agent that is `stuck?` (`"stale":
  true` in `--json`), and on one that quit (`stopped`).
- A session no agent is known in reads `unknown`: the wait times out and says
  so, since waiting longer would not change it.

### `wts tail`

The agent's last messages, from its transcript; `-n <k>` for how many,
`--json` for scripts. The transcript is the file the agent's hooks named
(`transcript_path`), else the one derived from the worktree's path
([How `wts brief` gathers and caches](watching.md#how-wts-brief-gathers-and-caches)).

### Rules for a caller without a terminal

- **Nothing waits on a terminal that is not there.** Without one on stdin, a
  creation never attaches (`--detach` says so explicitly): from an agent's pane
  it would `switch-client` and move *your* terminal.
- Pickers and confirmations exit 2 and name what to pass instead (`pass its id
  (wts task ls --json)`).
- Things is never read ([tasks.md](tasks.md#things-and-the-macos-permission)).

### JSON

Every listing answers `--json`; keys are added and never renamed.

- `wts status --json` is an array of sessions.
- The others are objects with `"version": 1`: `wts task ls --json`,
  `wts task show <id> --json`, `wts doc ls --json`, `wts doc show <slug>
  --json`, `wts brief --cached --json` (the last summaries, no model call),
  `wts gc --json` (the dry run's plan: what would go and why; never with
  `--apply`), `wts doctor --json`, `wts wait --json`, `wts tail --json`, and a
  creation's `--json`.
- `wts db sql`, `tables` and `row` answer `--json` with sqlite3's own array of
  rows, no envelope: a row is whatever the table holds.

### Exit codes

| Code | Meaning |
|------|---------|
| 0    | done |
| 1    | failed: a session that did not come back, a wait that timed out, a refused send |
| 2    | usage: an unknown option, a typo of a command, a picker with no terminal, a write that takes one |

### The skill

The skill (`wts setup claude --install` writes it, `wts doctor` checks it) is
this guide and the commands above, for the agent: when to read, when to
delegate, and what to ask you before doing: `rm`, `stop`, `gc --apply`, and
anything that calls the model.

## How it works

What an agent was told is recorded in the `seen` table, so a note rewritten a
second after it was read comes again, and nothing comes twice.
