# The work journal: `wts log`

`wts gc --apply` and `wts rm` archive what they tear down, and `wts log` prints
it as one JSON document: every finished session with its outcome, its diff, its
retrospective and a pointer to its transcript, for the six-month look back a
review needs.

```
wts log [--since <when>] [--until <when>] [--task <id>] [--brief]
        [--no-notes] [--no-things]
wts retro [name...] [--force] [--jobs <n>]
```

![wts task link labelling a finished session, wts ls showing the marker it adds, wts gc announcing what it would archive and then archiving it, the retrospective written by Claude, and wts task ls and wts log reporting what survived the teardown](journal.gif)

## Usage

```sh
wts log                             # the last 180 days, as JSON
wts log --since '-6 months'         # or an ISO date: --since 2026-04-01
wts log --since '-6 months' > work.json
wts log --brief                     # titles, outcomes, retros — without the bulk
wts retro                           # write the retrospectives gc could not
```

The document is one object with a `work` array and carries `version`. A work
item is a task, with its sessions (its attempts) nested under it; a session
that served no task is a work item of its own. Live sessions are in it too,
with the outcome `in-progress`. `--since` and `--until` take an ISO date or a
SQLite date modifier (`-6 months`, `start of year`).

`wts retro` writes the retrospectives gc could not (no model, a timeout). It
reads the archive, never the worktree, so it works any time.

## What is archived

Per finished session:

- the phrase it started from;
- the branch and its base;
- the outcome: `merged`, `squashed`, `remote-deleted`, `removed`, `abandoned`,
  or `unknown` for an entry `wts ls` purged because its worktree was gone
  ([sessions.md](sessions.md#the-registry)). That list, with `in-progress`, is
  closed: a reader can rely on it;
- the pull request, the commit subjects, the paths touched, the diffstat;
- the notes the agents left each other, the last brief;
- a four-line retrospective;
- a gzipped copy of the transcript.

Each work item carries the task it served ([tasks.md](tasks.md)).

### The retrospective

```
delivered: BalanceMovement and its 47 collaborators moved into packs/banking
resisted:  the Packwerk boundary check failed on two circular references
resolved:  inverted the dependency with an event rather than a privacy exception
abandoned: dropping the deprecated alias in the same PR — deferred a release
```

`wts gc --apply` asks Haiku for these four lines, once per finished session and
while the transcript is still there. `resisted` and `resolved` are the parts a
task title can never carry, and they are read mostly from **your own
corrections to the agent** ("no, that breaks idempotency", "revert that"),
which is the only place friction is recorded.

### The transcript copy

wts keeps a gzipped copy of the transcript in
`~/.local/state/wts/transcripts/`, about 2–5 MB per semester. `wts log` tells
you whether drilling into the raw conversation is still possible: each session
carries `transcript.available`, tested at export time rather than promised.

### Usage per session and per task

Each session carries `usage`: input, output, cache writes and reads, per model,
and `cost_usd` at API list prices ([Tokens and
cost](watching.md#tokens-and-cost)). Each work item carries the total of its
sessions: what a task cost over all its attempts. `null` where nothing was ever
counted.

## Where the model is called, and where it is not

- **Only in `wts gc --apply`**, and only after every destructive step has
  finished and been reported. A timeout, a missing `claude` or a Ctrl-C there
  costs nothing but text, which `wts retro` writes later from rows already in
  the database.
- **`wts rm` never calls it**: it is synchronous with a human waiting, and often
  used on work being abandoned.
- `wts gc --no-retro` and `WTS_NO_LLM=1` skip it; the facts are archived either
  way.
- A dry run (`wts gc` without `--apply`) writes nothing.

## Privacy

This is the most sensitive thing wts produces: prompts, commit subjects, file
paths, agent notes and a full transcript copy. The database is `chmod 600`, but
`wts log` prints all of it on stdout.

| To                         | Use |
|----------------------------|-----|
| drop the free text         | `wts log --no-notes` |
| drop the bulk              | `wts log --brief` |
| stop the transcript copy   | `WTS_ARCHIVE_TRANSCRIPT=0`: the archive points at the transcript without copying it |
| stop the capture altogether | `WTS_NO_ARCHIVE=1`: `wts rm` and `wts gc` archive nothing |

See also [What is sent to the model](../README.md#what-is-sent-to-the-model).

## How it works: why a retrospective

Why a retrospective and not just a pointer to the conversation: Claude Code
deletes transcripts after 30 days by default. On the machine this was built on:
275 transcripts, 148 MB, **none older than 30 days**. A self-assessment looks
six months back, so by the time you need it the only trace of *how* the work
went is already gone.

The archive keeps the session's row, its brief and its notes past the teardown:
otherwise the moment a piece of work becomes tellable is the moment wts forgets
it.
