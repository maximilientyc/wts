# wts — worktree sessions for parallel coding agents

`wts` creates a git worktree and a tmux session on it in one command, from a
layout you pick: by default an editor next to a Claude Code pane. It is made for
running several agents on the same repository at once without them stepping on
each other, and for finding your way back afterwards.

It is opinionated (zsh, tmux, tmuxinator, Claude Code) because it was built for
one person's workflow. It is shared in case that workflow is also yours.

![wts: a context document added to the library, a session started from a sentence with that document attached, prefix+a jumping straight to the agent that is blocked, the switcher answering it, attaching the document to an agent already running and stopping a finished session, then wts ls, wts brief, wts restore bringing the stopped session back and wts gc](docs/demo.gif)

## What you get

- **Starts from a sentence.** `wts "rate-limit the public API per key"` names
  the session for you and hands the sentence to Claude. → [Sessions](docs/sessions.md)
- **Shows what each agent is doing, and since when.** `wts ls` and the switcher
  (`prefix+s`) say which agent is blocked, idle or working, and on what
  question. → [Watching](docs/watching.md)
- **Tells you when one needs you.** A bell, a banner naming the session, a
  status-line count, and `prefix+a` to jump to the one waiting longest; `tab` in
  the switcher answers it. → [The switcher](docs/switcher.md)
- **Lets the agents know about each other.** Each agent is told which other
  sessions run and what they are on, and can leave notes for them.
  → [Agents](docs/agents.md)
- **Carries the context you keep re-pasting.** A spec or a conventions file,
  fetched once (`wts doc`), or a task that holds notes and documents
  (`wts task`). → [Documents](docs/documents.md), [Tasks](docs/tasks.md)
- **Survives reboots.** Every session is recorded in a small SQLite database,
  and `wts restore` rebuilds them all. → [Sessions](docs/sessions.md#stopping-and-restoring)
- **Cleans up after squash merges.** `wts gc` recognizes branches merged by
  squash or rebase, not only by ancestry. → [Cleanup](docs/cleanup.md)
- **Remembers finished work.** What a session did, how it ended and a
  four-line retrospective, kept for `wts log`. → [Journal](docs/journal.md)

## Install

Homebrew installs the dependencies and the zsh completion. Recent Homebrew
versions only load formulae from taps you trust, so trust the tap first:

```sh
brew trust maximilientyc/tap
brew install maximilientyc/tap/wts
```

Then the two integrations, both optional and recommended. Each prints what it
would add when run without `--install`: read it first.

```sh
wts setup tmux --install && tmux source-file ~/.tmux.conf   # the switcher, prefix+a, the status line
wts setup claude --install   # hooks, permissions and skill for Claude Code (~/.claude)
wts doctor                   # checks the dependencies and both integrations
```

macOS first; Linux is untested. Requirements, installing from source and what
each integration adds: [docs/install.md](docs/install.md).

## A first session

**Create one**, from a name or from a sentence:

```sh
cd ~/code/myapp
wts auth-form                               # ../myapp-worktrees/auth-form, branch auth-form
wts "rate-limit the public API per key"     # Claude proposes the name, starts on the task
```

You land in a tmux session: an editor, a Claude Code pane, and a shell window.
The worktree sits next to the repository, so each agent has its own copy of the
code. From tmux, `prefix+:` then `wts …` does the same from a freshly fetched
base.

**See them all:**

```sh
wts ls          # agent state and since when, branch, git delta, tmux state
wts ls --wide   # + tokens, API-price cost, model, and what a blocked agent waits on
```

Or press `prefix+s`: the switcher lists the sessions that need you first, with
a live preview of each agent's pane. `enter` switches to one.

**Answer an agent.** When one waits on a permission or a question, the pane
rings and a banner names the session. `prefix+a` jumps to it. In the switcher,
`tab` types the answer without leaving the popup.

**See where things stand:**

```
$ wts brief
auth-form  idle  auth-form  +322/-0 ^4  PR #42
  done: server-side email validation before sending
  next: decide the wording of the rate-limit error
```

Two lines per session, from git and the agent's transcript, summarized by
Claude Haiku and cached.

**Finish:**

```sh
wts stop auth-form      # tmux session only; the worktree and branch stay
wts rm auth-form        # session + worktree + branch + registry entry
wts gc                  # dry run: what is merged and can go
wts gc --apply          # removes it, and archives it for wts log
```

**Come back after a reboot.** Worktrees survive a reboot, tmux does not:

```sh
wts restore             # every session missing from tmux, Claude pre-filled to resume
```

## Commands

| Purpose | Command | What it does | Guide |
|---------|---------|--------------|-------|
| Create | `wts <name> ["<phrase>"] [layout] [context...]` | a worktree and a session; `--doc`, `--task`, `--detach`, `--json` | [sessions](docs/sessions.md) |
| | `wts "<phrase>" [layout] [context...]` | the same, named by Claude | [sessions](docs/sessions.md#starting-from-a-phrase) |
| | `wts new [-p layout] <name\|"phrase"...>` | several at once | [sessions](docs/sessions.md#several-at-once-wts-new) |
| | `wts layouts` | the layouts found, yours first | [layouts](docs/layouts.md) |
| Watch | `wts ls [--wide]` | sessions, agent state, git delta | [watching](docs/watching.md) |
| | `wts status [--json\|--table [--wide]\|--fzf]` | the same, for scripts | [watching](docs/watching.md#wts-status---json) |
| | `wts brief [name...]` | done / next per session | [watching](docs/watching.md#where-each-session-stands-wts-brief) |
| | `wts pr [name] \| pr --refresh` | open or cache the pull requests | [watching](docs/watching.md#pull-requests) |
| | `wts keys` | the switcher's keys and the tmux bindings | [switcher](docs/switcher.md) |
| Talk to an agent | `wts send <session> [--answer\|--force] <text...>` | type into its pane | [agents](docs/agents.md#wts-send) |
| | `wts wait <session>...` | return once it stops working | [agents](docs/agents.md#wts-wait) |
| | `wts tail <session> [-n <k>]` | its last messages | [agents](docs/agents.md#wts-tail) |
| | `wts db …` | the shared database, and notes between agents | [agents](docs/agents.md#agents-share-state-wts-db) |
| Context | `wts doc add\|ls\|show\|sync\|forget\|use\|tools` | the document library | [documents](docs/documents.md) |
| | `wts task ls\|show\|link\|unlink\|new\|add\|note\|edit\|doc\|done` | tasks and what they carry | [tasks](docs/tasks.md) |
| Finish | `wts stop <name>` | close the tmux session, keep the rest | [sessions](docs/sessions.md#stopping-and-restoring) |
| | `wts restore [name...]` | bring stopped sessions back | [sessions](docs/sessions.md#stopping-and-restoring) |
| | `wts rm <name> [-f]` | remove a session entirely | [sessions](docs/sessions.md#removing-a-session) |
| | `wts gc [--apply] [--all] …` | clean up what is merged | [cleanup](docs/cleanup.md) |
| Journal | `wts log [--since <when>] …` | finished work, as JSON | [journal](docs/journal.md) |
| | `wts retro [name...]` | write the missing retrospectives | [journal](docs/journal.md) |
| Setup | `wts setup tmux\|git\|claude [--install]` | the integrations | [install](docs/install.md) |
| | `wts doctor [--json]` | check what wts needs | [install](docs/install.md#checking-it-wts-doctor) |
| | `wts help [<command>]`, `wts version` | | |

`wts help` prints the full synopsis, and `wts <command> --help` each command's.
Every command answers `--help` with its own usage, and does nothing else. A
command that did not do what was asked exits non-zero: `wts restore` when a
session could not come back, `wts task unlink` on a name that is no session.

## Keys

From the tmux snippet (`wts setup tmux`):

| Key                     | Action |
|-------------------------|--------|
| `prefix+s`              | open the switcher (replaces tmux's `choose-tree -s`) |
| `prefix+a`              | jump to the next agent waiting |
| `prefix+g`              | new session, prompt pre-filled with `wts ` |
| `prefix+:` then `wts …` | new session, from a fresh base |

In the switcher (the popup shows them too; `?` unfolds the full list):

| Key        | Action |
|------------|--------|
| `enter`    | switch, or choose for the task |
| `tab`      | reply to the agent, or note a task |
| `ctrl-g`   | only what needs you, or every row |
| `ctrl-x`   | stop the session, keep the worktree (`wts stop`) |
| `ctrl-d`   | rm session (`wts rm`), or close a local task (`wts task done`) |
| `ctrl-o`   | open the pull request on GitHub (`wts pr`) |
| `ctrl-e`   | attach a context document (`wts doc use`, or `wts task doc` on a task) |
| `ctrl-t`   | new task (`wts task new`; empty: from Things, `wts task add`) |
| `ctrl-f` / `ctrl-b` | scroll the preview half a page |
| `ctrl-r`   | reload the list now |
| `esc`      | close, or leave reply mode |
| `?`        | show or hide these keys |

## Guides

| Guide | What it covers |
|-------|----------------|
| [install.md](docs/install.md) | requirements, Homebrew and source, the tmux and Claude Code integrations, `wts doctor` |
| [sessions.md](docs/sessions.md) | creating, naming, branches, `wts new`, creating from tmux, stop, restore, rm |
| [watching.md](docs/watching.md) | agent states, notifications, `wts brief`, tokens and cost, pull requests |
| [switcher.md](docs/switcher.md) | the `prefix+s` popup: keys, reply mode, the needs-you view, how it refreshes |
| [documents.md](docs/documents.md) | the context document library, `wts doc` |
| [tasks.md](docs/tasks.md) | tasks, their notes and documents, Things, task rows in the switcher |
| [cleanup.md](docs/cleanup.md) | `wts gc`: what it removes, its safety rules, how a merge is recognized |
| [journal.md](docs/journal.md) | the work journal: `wts log`, retrospectives, what is archived |
| [agents.md](docs/agents.md) | what agents are told about each other, `wts db`, driving wts from an agent |
| [layouts.md](docs/layouts.md) | writing your own layout, the variables it receives |
| [configuration.md](docs/configuration.md) | every variable, base branch detection, monorepos, large repositories |
| [upgrading.md](docs/upgrading.md) | upgrading from 0.x to 1.0, and rolling back |

Release history is in [CHANGELOG.md](CHANGELOG.md).

## What is sent to the model

wts calls the model through your own `claude -p`, and only from commands you
type:

| Command | What it sends |
|---------|---------------|
| `wts "<phrase>"` (no name) | the phrase, to propose a name |
| `wts brief` | the branch's commit log and diff stats, the session's starting prompt, your last message to the agent, and the tail (about 1,500 characters) of the agent's recent messages |
| `wts doc add`, `wts doc sync` | the document's URL; `claude` then reads the page with your own connectors |
| `wts gc --apply`, `wts retro` | per finished session: the task as asked, the commit subjects, the diffstat, the files touched, whether it shipped, and the exchange between you and the agent from its transcript, for a four-line retrospective |

- `wts ls`, the switcher and the hooks never call it. Neither does `wts rm`.
- Naming, `wts brief` and the retrospectives run with MCP and tools off, and
  ask for a JSON answer against a schema. What each call cost is counted with
  the session's usage (`wts ls --wide`, [Tokens and
  cost](docs/watching.md#tokens-and-cost)).
- `wts doc` is the exception, since reading a page is its job: each fetch is
  capped at `WTS_DOC_BUDGET_USD` (1 USD) and `WTS_DOC_MAX_TURNS` (8 turns).
- `WTS_NO_LLM=1` never calls the model: names are derived locally, `wts brief`
  shows the raw facts, documents stay pointers, retrospectives are skipped.
- Things is read only by a command you type in a terminal (or with
  `WTS_THINGS_FROM_SCRIPT=1`); the first read makes macOS ask for permission ([tasks.md](docs/tasks.md#things-and-the-macos-permission)).
- The work journal is the most sensitive thing wts produces: prompts, commit
  subjects, file paths, agent notes and a transcript copy
  ([journal.md](docs/journal.md#privacy)).

## Known limitations

- **Session names are global** to the tmux server: two `auth-form` worktrees in
  two repositories would share one session and one registry key, so
  `wts auth-form` is refused while another repository has that session. Prefix
  the name (`api-auth-form`).
- **A session cannot be named after a subcommand**: a session named `doc`,
  `pr`, `rm` or any other command of `wts help` is shadowed by the command.
- **macOS first.** Linux is untested.
- **Some Claude Code internals are undocumented**: the `tmux` field of
  `~/.claude/sessions/<pid>.json` (used to target the preview pane), the record
  types of transcript `.jsonl` files and the way their directory is named (the
  fallback when the hooks have not reported a transcript's path). When
  they change, the affected columns and summaries degrade to `-` or raw facts;
  nothing else breaks.
- The restore pre-fill (`print -z`) assumes zsh in the panes.
- `wts gc` acts on the repository of the current directory (`wts rm` finds the
  session's repository through the registry).
- **A document is written in clear text inside the worktree**, and one fetched
  through `WebFetch` is a model's rendering of the page, not the page
  ([documents.md](docs/documents.md#privacy-and-fidelity)).

## Contributing

Issues and pull requests are welcome. Run `zsh test/smoke.zsh` before
submitting: it drives a throwaway repository on an isolated tmux server, without
calling the model. Notes on the code are in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
