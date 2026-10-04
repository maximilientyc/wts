# Tasks

A session lasts days and dies at the merge; the task lasts months. So the task
is where the material belongs: notes, links, documents, and what earlier
attempts learned. `wts <name> --task <id>` hands **all** of it to the new
session. A task is a Things 3 task or a local one, and serves one to N
sessions.

```
wts task ls [--all] [--json] | show <id> [--json]
wts task link [<id>] [session] | unlink [session]
wts task new "<title>" | add [<id>] | edit [<id>] | done [<id>]
wts task note [<id>] "<text>" | note [<id>] --clear
wts task doc [<id>] [<doc>] | doc [<id>] --rm <slug>
```

## A task is where the context lives

```sh
wts task add                        # pick a Things task; it joins wts's list
wts task new "Validate the signup form"   # or a task wts holds by itself
wts task note "the spec moved to the new Notion page"   # from inside a worktree
wts task edit                       # longer context, in $EDITOR
wts task doc api-spec               # a document every session on this task gets
wts audit-trail --task <id>         # a session that opens on all of the above
wts task done                       # a local task is finished: off the list
```

- `note`, `edit` and `doc` default to the task of the session you are in, so
  inside a worktree they need no id.
- What they write is wts's own: Things stays read-only, and a note you add here
  is **not** overwritten the next time wts refreshes the task from Things,
  which a column on the task would have been.
- `wts task link` links a session to a task after its creation; `unlink` undoes
  it, and exits non-zero on a name that is no session.
- `wts task show <id>` lists what the task carries, its sessions and their
  usage ([Tokens and cost](watching.md#tokens-and-cost)).
- `wts task ls` reads Things again, the one command that does.

A task stays on the list, and comes back after each session on it is removed,
until it is closed: in Things for a Things task, with `wts task done` (or
`ctrl-d` on its row) for one wts holds by itself.

All of it survives the teardown: the notes and documents belong to the task,
not to the session that was removed with it.

## How the task reaches the session

Four channels carry it, and they are four because each one fails differently:

1. **The agent's opening prompt** is the task title, when you typed no phrase.
2. **The documents on the task** are attached like `--doc` ones. Already
   fetched, so creation pays nothing.
3. **`.wts/context.md` opens with the task**: its title, status, your notes,
   its *previous attempts* (the last three archived sessions with their
   outcome, PR and retrospective, so a retry starts where the last one
   stopped), its links, before the documents. This is the only channel the
   agent reads *before its first turn*. It is capped at `WTS_TASK_MAX_CHARS`
   (16000).
4. **The `SessionStart` hook repeats it**, and it is the only one that comes
   back: Claude Code re-runs the hook after `/clear`, `/compact` and a resume,
   while a prompt and a file are read once ([agents.md](agents.md#what-every-agent-is-told)).

### The links you keep in a task become context too

`--task` reads the URLs out of the task's notes (the Notion page, the meeting
minutes, the Slack thread) and attaches them as [context
documents](documents.md).

- They are recorded as **pointers**, not fetched. `wts doc sync` fetches them
  later, at your pace.
- A document you attached with `wts task doc` wins over a pointer to the same
  page.

## Tasks in the switcher

![a task given a note and a context document, wts task show listing what it now carries, the switcher showing that task as a row with a count of its context, its preview holding the note and the document, tab typing another note straight onto it without leaving the popup, and enter starting a session on the task whose agent opens on the context file](tasks.gif)

Under the sessions, the [switcher](switcher.md) lists the **open tasks**: the
other half of the question it answers. Which makes the popup the place you
decide *what* to do, not only *where* to go back to.

- A task row reads `task` in the AGENT column, and `N ctx` in DELTA: how many
  documents, links and notes it already carries, so you can see at a glance
  whether a piece of work is ready to start.
- Tasks with no session come first. A task some sessions already serve stays
  listed after them, with `N session(s)` in SUBJECT, and its sessions carry the
  `@` in theirs.
- Ten tasks at most, most recently touched first (`WTS_SWITCH_TASKS=<n>`, `0` to
  hide them).

The preview is the task itself: title, status, the sessions started from it,
the notes you kept on it, its links, its documents. The sessions are the live
ones with their agent's state, then the last three finished ones as *previous
attempts*: outcome, PR, and what was delivered, what resisted, how it was
resolved, what was abandoned, from their [retrospectives](journal.md).

### Keys on a task row

**`enter` asks what to do with it**, on a second screen in the same popup:

| Choice | What it does |
|--------|--------------|
| new session from a prompt | pre-filled with the title; the agent opens on it and wts names the session from it (`wts-fresh "<prompt>" --task <id>`) |
| new session from a branch name | pre-filled with a name derived from the title; a `feature/` typed by habit is dropped, wts adds its own prefix (`wts-fresh <name> --task <id>`) |
| attach to a session | for work that started before the task was written down (`wts task link`), then switches to it. The agent already running sees the task at its next `/clear` |

Creation goes through `wts-fresh`, the same path as `prefix+g`: the branch is
cut from a freshly fetched base and it refuses outside a repository
([sessions.md](sessions.md#creating-from-tmux)). `esc` goes back to the list. On
a task some sessions already serve, `enter` starts one more, for a second
attempt next to the first.

| Key      | On a task row |
|----------|---------------|
| `tab`    | **notes on it**, the way `tab` replies to an agent: the prompt becomes `note on <task>>` and `enter` appends the line to the task's notes. The fastest way to put something where the next session on this task will find it |
| `ctrl-e` | **attaches a document to the task** rather than to a session, so every later attempt at it inherits the document |
| `ctrl-d` | **closes it**, after a y/N prompt (`wts task done`): the task leaves the list for good, its notes, documents and past sessions stay. Only a task wts holds by itself: a Things task is completed in Things, and leaves the list at the next `wts task ls` |

### Creating a task: `ctrl-t`

![ctrl-t typing a task into the switcher, the new row selected with its preview, enter on it offering a new session from a prompt or a branch name or attaching it to a session, a session created from the branch name feature/migration-guide, and a second task attached to an existing session](new-task.gif)

Anywhere in the list, **`ctrl-t` creates a task**:

1. the prompt becomes `new task>`;
2. you type the title, and `enter` creates it (`wts task new`) and puts the
   cursor on it, ready for `tab`, `ctrl-e` or `enter`;
3. on an empty title, `enter` pulls one in from Things instead
   (`wts task add`), where Things is installed.

## Things and the macOS permission

The first `wts task add` on macOS 15+ makes the system ask whether your terminal
may *access data from other apps*: Things keeps its database in its own
container.

- Say yes once and wts remembers that it can read it.
- Say no and it stops offering Things at all. `wts task new "<title>"` keeps
  working either way, on a task wts holds by itself, and `wts task add` is still
  how you try again once you have changed your mind in System Settings.
- Nothing else ever opens Things: not `wts ls`, not the switcher, not a hook.
- Things is never read without a terminal on stdin: macOS asks before another
  app's data is read, and an agent is not you. `WTS_THINGS_FROM_SCRIPT=1` lets a
  cron job; never set it for an agent.
- `WTS_NO_THINGS=1` never reads Things (a machine without it, or to keep the
  macOS prompt away). `WTS_THINGS_DB` names the Things database to read instead
  of the one found in Things' container.

## How it works

**Why links are pointers.** A task carries one to three links, the fetch model
is sonnet with a 90 s cap, and paying that at creation would put minutes in
front of a starting agent. A pointer is also likelier to work: a Slack
permalink or a private Notion page is exactly what the sandboxed fetch cannot
read and the agent in the pane can.
