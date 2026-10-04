# Sessions

How to create a session (from a name, from a sentence, several at once, from
tmux), which branch it gets, how to stop it and bring it back after a reboot,
and how to remove it. Watching a running session is in
[watching.md](watching.md); cleaning up after a merge is in
[cleanup.md](cleanup.md).

```
wts <name> [layout] [context...]
wts <name> "<phrase>" [layout] [context...]
wts "<phrase>" [layout] [context...]
wts new [-p layout] <name|"phrase"...>
wts restore [name...]
wts stop <name>
wts rm <name> [-f]
```

| Argument     | Meaning |
|--------------|---------|
| `<name>`     | name of the worktree AND of the tmux session |
| `<phrase>`   | the task in plain words, quoted; Claude starts with it. Without `<name>`, Claude proposes the name |
| `[layout]`   | tmuxinator layout (default: `default`), see `wts layouts` and [layouts.md](layouts.md) |
| `[context]`  | exposed to the layout as `$WTS_CONTEXT` |
| `--doc <d>`  | attach a [context document](documents.md) (a slug of `wts doc ls`, a URL or a markdown file); repeatable, and a bare `--doc` at the end picks one |
| `--task <t>` | the session serves this [task](tasks.md): its notes and documents become the agent's context; a bare `--task` at the end picks one |
| `--detach`   | start the session without attaching to it; implied when stdin is not a terminal (an agent's shell, a script) |
| `--json`     | detached, progress on stderr, and the session on stdout as JSON: name, branch, worktree, task (an array for `new`) |

`--doc` and `--task` work with `new` too. They label a session, they do not
name one: the name (or the phrase) comes first.

## Creating a session

```sh
cd ~/code/myapp
wts auth-form                          # ../myapp-worktrees/auth-form, branch auth-form
wts auth-form feature                  # your "feature" layout: branch feature/auth-form
wts fix-ABC123 sentry ABC123           # "ABC123" reaches the layout as $WTS_CONTEXT
wts review/login-flow                  # an existing origin branch: checked out for review
wts auth-form "rate-limit it" --doc api-spec   # with a context document attached
```

Slashes become `-` in the worktree folder and the session name
(`review/login-flow` → `review-login-flow`); the git branch keeps its full name.

Running the same command twice is safe:

- An existing worktree is reused.
- An existing session is detected by its **exact** name, and `wts` attaches to
  it (or switches client, inside tmux) without running tmuxinator again.
- The registry entry is rewritten on each launch; `created_at` and `prompt` are
  kept.

### A typo is not a session

`wts lsit` alone, when no session and no branch has that name, prints "did you
mean `wts ls`?", exits 2 and creates nothing.

- A word counts as a typo within one edit of a command: two edits from five
  letters on, and a swap of two letters is one edit.
- Never under three letters.
- To create a session by that name anyway, give a second word, a layout:
  `wts lsit default`.

## Starting from a phrase

```sh
wts csv-export "the export times out above 10k rows"   # name given: instant
wts "the export times out above 10k rows"              # name proposed: export-timeout-large-rows
wts "the export times out above 10k rows" sentry       # layout after the phrase
```

A **phrase** is an argument containing a blank, in first or second position: no
session, branch or layout name contains one.

- It is removed from the positional arguments; layout and context keep their
  places.
- The Claude pane starts with `claude "<phrase>"`.
- The phrase is stored in the registry, where it fills the SUBJECT column until
  Claude names the conversation.

**Quote the phrase.** `wts fix the export` splits it and takes `the` as a
layout; the error message says so. In the tmux prompt, an apostrophe needs
quotes too: `wts "don't cache the header"`.

### Without a name

`wts-name` asks Claude Haiku for a 2–4 word kebab-case slug (3 to 15 s).

- **Ctrl-C** while it runs does not abort the creation: it takes the name
  derived from the phrase, and says after how long.
- The name is derived locally from the phrase when the call passes
  `WTS_NAME_TIMEOUT`, without `claude`, with `WTS_NO_LLM=1`, or when the answer
  is not a name. A warning on stderr says which of those happened, an
  unrecognized `WTS_MODEL` included, which `claude` answers in prose rather
  than with a failure.
- The call is isolated: `--safe-mode`, hooks disabled, no MCP server, no tool,
  no transcript, run outside any worktree. What it sends is in [What is sent to
  the model](../README.md#what-is-sent-to-the-model).

**A proposed name is always unique.** It gets `-2`, `-3`… until it is free
everywhere: worktree folder, registry, tmux session, local or remote branch.
Otherwise branch resolution would silently check out another session's branch.
A name you give yourself keeps the normal behavior, checkout of an existing
branch included.

## Branch resolution

When creating the worktree, `wts` picks the branch in this order:

1. **Existing local branch** → checkout.
2. **Existing branch on `origin`** → fetch, then checkout with tracking. This is
   the review case: you pick up existing work. Skipped offline or without
   `origin`.
3. **Otherwise** → new branch from the [base
   branch](configuration.md#base-branch-detection).

The branch name is the layout's [branch prefix](layouts.md#branch-prefix)
followed by the session name. To review an origin branch by its exact name, use
a layout without prefix, such as `default`.

## Several at once: `wts new`

```sh
wts new cors rate-limit csv-export       # default layout
wts new -p sentry ABC123 DEF456
wts new "rate-limit the API per key" "export as CSV"   # names proposed one by one
```

`wts new` starts each session detached, then attaches to the first. Creations
are sequential: in parallel, two similar phrases could get the same name.

`wts a & wts b & wts c` does **not** work: the normal flow ends with
`exec tmuxinator start`, so the first call replaces the process.

## Creating from tmux

`prefix+:` opens tmux's command prompt; type `wts` followed by the **usual
`wts` arguments** (`prefix+g` pre-fills it). You get the prompt's history for
free.

```
wts auth-form
wts fix-ABC123 sentry "timeout on /api/v2"
wts "the PWA header hides the profile button"
```

The command goes through `wts-fresh`, which adds two guarantees:

1. **Outside a git repository it refuses**: nothing is created.
2. **The branch is cut from a freshly fetched `origin/<default>`.** If the
   fetch fails (offline, no `origin`), it **aborts**: a worktree started from a
   stale base is exactly what it exists to prevent. Offline, `wts <name>` from a
   shell still works, on the local base.

What else to know:

- Run from inside a wts session, creation is attached to the main repository,
  not the current worktree (no nested worktrees).
- If the branch already exists, it is checked out and the base is not used;
  nothing is ever rebased.
- tmux splits the arguments itself, so quote contexts with spaces. An unclosed
  apostrophe swallows the rest of the line, and `wts-fresh` says so.
- A phrase without a name is named in the background while the fetch runs.
- When `wts` fails, the window stays open on its message until a key is
  pressed.
- `ls`, `status`, `brief`, `restore`, `stop`, `pr`, `doc`, `db`, `log`,
  `retro`, `task`, `send`, `wait`, `tail`, `layouts`, `keys`, `doctor`,
  `setup`, `help` and `version` are passed through without fetching; `gc` and
  `rm` run from the main repository.

The default branch is detected, never hardcoded: `WTS_BASE_BRANCH`, local
`origin/HEAD`, `git ls-remote --symref origin HEAD`, then `origin/main` and
`origin/master`. A missing `origin/HEAD` is restored along the way. The local
base branch is fast-forwarded when it is safe: a bonus, never blocking.

The new window does not see the calling pane's environment: when the repository
has an `.envrc` and direnv is installed, `wts` runs through `direnv exec`.

## Stopping and restoring

A reboot kills the tmux server, **not the worktrees**. `wts` records every
session in its state database, so it can rebuild them.

```sh
wts stop auth-form        # tmux session only
wts restore auth-form     # brings it back
wts restore               # every registered session missing from tmux
```

`wts stop <name>` kills the tmux session; the worktree, the branch and the
registry entry stay, and `wts restore <name>` replays it. It leaves on purpose
the same state a reboot leaves.

`wts restore [name...]` replays `tmuxinator start --no-attach` for every
registered session missing from tmux whose worktree still exists, all of them
without arguments. It skips sessions that are already running, and exits
non-zero when a session could not come back. It never attaches: restoring eight
sessions should not steal your terminal.

### The Claude pane on restore

During `wts restore`, layouts see `WTS_RESTORE=1` and skip heavy commands:
otherwise eight sessions mean eight `claude` and eight dependency installs at
once. The Claude pane is not empty for all that: the command is
**pre-filled** on the pane's zsh command line, press Enter to run it.

| What wts found | Pre-filled |
|----------------|------------|
| The hooks recorded the agent's conversation and its transcript still exists (`WTS_RESUME_ID`) | `claude --resume <id>` |
| Only a conversation for the pane's directory (`WTS_RESUME=1`) | `claude --continue` |
| Neither | `claude` |

`--resume <id>` is the agent's own conversation, where `--continue` takes the
most recent one in the directory, which may be a side chat. Plain `claude`
when there is neither, since both would fail. The leading space keeps the
command out of your history (`histignorespace`). The block that does it is in
[layouts.md](layouts.md#the-claude-pane-on-restore).

### After a reboot

`wts restore` is manual. To run it after a reboot, add to `~/.zshrc`; it only
fires once, on a cold tmux server:

```sh
if [[ -z "$TMUX" ]] && ! tmux has-session 2>/dev/null; then
  wts restore >/dev/null 2>&1
fi
```

## Removing a session

```sh
wts rm auth-form          # session + worktree + branch + registry entry
wts rm auth-form -f       # also a dirty worktree or an unmerged branch
wts rm auth-frm -f        # typo-tolerant: proposes auth-form, asks y/N
```

`wts rm` refuses:

- a worktree with uncommitted changes, unless `-f`;
- the current session;
- a guess: an exact name goes through, a resolved one is shown and confirmed,
  and without a terminal to ask (a script, the switcher) it is refused.

It finds the session's worktree and repository through the registry, so it
works from any directory, on a session of any repository. Without `-f` it
deletes a branch merged by squash or rebase too ([cleanup.md](cleanup.md#wts-rm-and-a-merged-branch)),
and it archives what it tears down for the [work journal](journal.md).

`wts rm`, `wts stop` and `wts brief` tolerate typos: substring match, then fzf
fuzzy match, then edit distance. When several sessions match, an fzf picker
opens.

## How it works

### The registry

Every session is a row of the `sessions` table of the state database,
`${XDG_STATE_HOME:-~/.local/state}/wts/wts.db`:

```
$ wts db sql "select * from sessions where name = 'auth-form'" --json
[{"name":"auth-form","profile":"feature","repo_root":"/home/me/code/myapp",
  "worktree":"/home/me/code/myapp-worktrees/auth-form","branch":"feature/auth-form",
  "subdir":"","context":"","prompt":"validate the email server-side before sending",
  "docs":"[]","created_at":"2026-09-05T15:12:41Z"}]
```

The same database holds the `wts brief` cache, the fetched documents, the stale
guard's pane hashes and the agents' notes. It runs in WAL mode: the switcher
and any number of agents read while one process writes, and a second writer
waits its turn instead of overwriting the first.

`wts ls` purges entries whose worktree is gone, after archiving what the
registry knew about them (outcome `unknown` in `wts log`).

Restoring is a **declarative replay**, not a snapshot like tmux-resurrect: a
wts session is fully described by its name, layout and context, so replaying
the layout is more faithful.

### Exact session names

An existing session is detected with `tmux has-session -t =<name>`, an
**exact** match: without `=`, tmux accepts a prefix and `fix-login` would match
`fix-login-2`.

### Why `--no-track`

In case 3 of [branch resolution](#branch-resolution), the branch is created
with `--no-track`. Otherwise, with a remote base (`origin/main`, which
`prefix+: wts` uses), git would make the new branch track the base:
`git status` would say "behind origin/main by 47", which an agent reads and
acts on; `git pull` would merge the base; and `wts gc` would never see the
remote branch disappear.
