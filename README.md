# wts — worktree sessions for parallel coding agents

`wts` creates a git worktree and a tmux session on it in one command, from a
layout you pick — by default an editor next to a Claude Code pane. It is made for
running several agents on the same repository at once without them stepping on
each other, and for finding your way back afterwards:

- **Survives reboots.** Every session is recorded as *(name, layout, context)* in a
  small SQLite database, so `wts restore` rebuilds them all — worktrees survive a
  reboot, tmux does not.
- **Lets the agents know about each other.** Each Claude Code agent started in a
  wts session is told which other sessions are running and what they are on, and
  can query the shared state and leave notes for the others (`wts db`).
- **Shows what each agent is doing, and since when.** `wts ls` and the fzf
  switcher (`prefix+s`) tell you which Claude Code agent is blocked, idle or
  working, for how long, and on what question — from the agent's own hooks —
  with a stale guard that catches agents claiming to work on a frozen pane.
- **Tells you when one needs you.** A bell on the pane and a banner naming the
  session when an agent waits for a permission or an answer, a status-line
  segment counting them, and `prefix+a` to jump to the one waiting longest.
- **Cleans up after squash merges.** `wts gc` compares patch-ids against
  `origin/<base>`, so branches merged by squash or rebase are recognized, not left
  to pile up.
- **Tells you where you left off.** `wts brief` prints a two-line *done / next* per
  session, from git and the agent's transcript.
- **Starts from a sentence.** `wts "rate-limit the public API per key"` names the
  session for you and hands the sentence to Claude.
- **Carries the context you keep re-pasting.** `wts doc add <url|path>` puts a
  spec, an architecture page or a file of conventions in a small library, fetched
  once, and `--doc <slug>` attaches it: the agent opens on the document.

It is opinionated — zsh, tmux, tmuxinator, Claude Code — because it was built for
one person's workflow. It is shared in case that workflow is also yours.

> **Upgrading from 0.x?** 1.0 moves the state to SQLite. The import is automatic;
> see [Upgrading to 1.0](#upgrading-to-10) for the steps and the rollback.

![wts: a context document added to the library, a session started from a sentence with that document attached, prefix+a jumping straight to the agent that is blocked, the switcher answering it, attaching the document to an agent already running and stopping a finished session, then wts ls, wts brief, wts restore bringing the stopped session back and wts gc](docs/demo.gif)

## Requirements

- macOS (Linux is untested)
- zsh, git, tmux, [tmuxinator](https://github.com/tmuxinator/tmuxinator), fzf, jq,
  sqlite3 (3.38+, JSON built in), perl, curl (macOS ships sqlite3; jq only with
  recent releases, and Homebrew installs it)
- Optional: [Claude Code](https://claude.com/claude-code), tested with 2.1.x — agent
  state columns, naming from a phrase, `wts brief`, resume on restore. Without it
  everything else works and the agent columns show `-`.
- Optional: [direnv](https://direnv.net), for a per-repository `WTS_SUBDIR`
- Optional: [gh](https://cli.github.com), for `ctrl-o` in the switcher and `wts pr`
  (open the session's pull request). Without it the key is not offered.

`wts doctor` checks all of it: what is missing, which switcher features an older
fzf turns off (reply mode below 0.45, the fitted preview below 0.46, the key
footer below 0.65), whether `claude agents --json` answers, and whether the tmux
snippet and the Claude hooks are installed and come from this wts. It exits 1
when something required is missing. A creation also checks for tmux and
tmuxinator itself, before it makes a branch or a worktree.

## Install

**Homebrew** (dependencies and zsh completion included). Recent Homebrew versions
only load formulae from taps you trust, so trust the tap first:

```sh
brew trust maximilientyc/tap
brew install maximilientyc/tap/wts
```

**From source:**

```sh
brew install tmux tmuxinator fzf jq
git clone https://github.com/maximilientyc/wts
cd wts
make install PREFIX=~/.local
```

Then make sure `~/.local/bin` is in your `PATH`, and add the completion directory
to `fpath` in `~/.zshrc`, before `compinit` runs (before oh-my-zsh, if you use it):

```zsh
fpath=(~/.local/share/zsh/site-functions $fpath)
```

**tmux integration** (optional, recommended):

```sh
wts setup tmux              # read it first
wts setup tmux --install && tmux source-file ~/.tmux.conf
```

`--install` writes the block between `# >>> wts` and `# <<< wts <<<` markers in
`~/.tmux.conf` (backup kept), and replaces it on the next upgrade instead of
adding a second one; a block appended by an older wts, without markers, is
replaced too. Run it again after `brew upgrade wts` when `wts doctor` says the
snippet is older than wts.

| Key                          | Action                                                  |
|------------------------------|---------------------------------------------------------|
| `prefix+s`                   | session switcher — **replaces** tmux's default `choose-tree -s` |
| `prefix+a`                   | jump to the agent that has waited for you the longest   |
| `prefix+:` then `wts …`      | create a session from a freshly fetched base            |
| `prefix+g`                   | the same prompt, pre-filled with `wts `                 |

The snippet also appends a segment to `status-right` — `wts: 2 blocked · 1
idle`, nothing when nobody needs you — so keep it after the lines that set
`status-right` (a theme's), or they overwrite it. Move that line out of the
block, below your theme, and `--install` leaves it there and does not add a
second one. It uses absolute paths: tmux
runs `command-alias` programs directly, without a shell, so neither `~` nor
`PATH` lookups are reliable there. Homebrew paths point to the stable `opt/wts`
location and survive `brew upgrade`.

**Claude Code integration** (optional, recommended): six hooks, the
permissions for wts's read-only verbs, and a skill. `SessionStart` tells every
agent started in a wts session about the other sessions — see [Agents share
state](#agents-share-state-wts-db); four others record what the agent reports
about itself, which is what dates the states and rings when one needs you — see
[When an agent needs you](#when-an-agent-needs-you); `PostToolUse` records the
files it edits. The skill (`~/.claude/skills/wts/SKILL.md`) is what lets a
Claude started *anywhere* find wts when you ask about parallel work — see
[Driving wts from an agent](#driving-wts-from-an-agent).

```sh
wts setup claude             # read it first
wts setup claude --install   # adds it to ~/.claude/settings.json (backup kept), writes the skill
```

## Quick start

```sh
cd ~/code/myapp
wts auth-form                          # ../myapp-worktrees/auth-form, branch auth-form
wts "rate-limit the public API per key"   # Claude proposes the name, starts on the task
wts ls                                 # agent state, branch, git delta, tmux state
                                       # (and REPO, once sessions span two repositories)
wts ls --wide                          # + tokens, API-price cost and model per session
wts stop auth-form                     # tmux session only; wts restore brings it back
wts rm auth-form -f                    # session + worktree + branch + registry entry
```

## Usage

```
wts <name> ["<phrase>"] [layout] [context...] [--doc <d>] [--task [<id>]] [--detach] [--json]
wts "<phrase>" [layout] [context...] [--doc <d>] [--task [<id>]] [--detach] [--json]
wts new [-p layout] [--doc <d>] [--task [<id>]] [--detach] [--json] <name|"phrase">...
wts doc add <url|path> | ls [--json] | show [--json] | sync | forget | use <slug> [name] | tools
wts ls [--wide]
wts status [--json|--table [--wide]|--fzf]
wts brief [name...] | brief --cached [--json] [name...]
wts send <name> <text...>
wts wait <name>... [--until <state>,...] [--timeout <s>] [--json]
wts tail <name> [-n <k>] [--json]
wts restore [name...]
wts stop <name>
wts pr [name]
wts rm <name> [-f]
wts gc [--all] [--all-branches] [--apply] [--no-fetch] [--no-retro] | gc [...] --json
wts log [--since <when>] [--until <when>] [--task <id>] [--brief] [--no-notes] [--no-things]
wts retro [name...] [--force] [--jobs <n>]
wts task ls [--all] [--json] | show <id> [--json] | link [<id>] [name] | unlink [name] | new "<title>"
wts task add [<id>] | note [<id>] "<text>" | note [<id>] --clear | edit [<id>]
wts task doc [<id>] [<url|slug>] | doc [<id>] --rm <slug> | done [<id>]
wts layouts
wts keys
wts doctor [--json]
wts db path | schema | sql "<SELECT ...>" | notes [--all] | get | set | del
wts setup tmux [--install] | git | claude [--install]
wts help [<command>] | wts <command> --help | wts version
```

Every command answers `--help` with its own usage, and does nothing else: `wts
new --help` used to start a session named `--help`. `wts ls` takes `--wide` alone
(`wts status --json` is the one with formats), and a command that did not do
what was asked exits non-zero: `wts restore` when a session could not come back,
`wts task unlink` on a name that is no session.

**A typo is not a session.** `wts lsit` alone, when no session and no branch has
that name, prints "did you mean `wts ls`?", exits 2 and creates nothing. A word
counts as a typo within one edit of a command (two from five letters on; a swap
of two letters is one edit), never under three letters. To create a session by
that name anyway, give a second word — a layout: `wts lsit default`.

```sh
wts auth-form feature                  # your "feature" layout: branch feature/auth-form
wts fix-ABC123 sentry ABC123           # "ABC123" reaches the layout as $WTS_CONTEXT
wts new cors rate-limit csv-export     # three worktrees and sessions at once
wts review/login-flow                  # an existing origin branch: checked out for review
wts auth-form "rate-limit it" --doc api-spec   # with a context document attached
wts rm auth-frm -f                     # typo-tolerant: proposes auth-form, asks y/N
```

Slashes become `-` in the worktree folder and session name (`review/login-flow` →
`review-login-flow`); the git branch keeps its full name. `wts rm`, `wts stop` and `wts brief`
tolerate typos: substring match, then fzf fuzzy match, then edit distance; when
several sessions match, an fzf picker opens. `wts rm` never acts on a guess: an
exact name goes through, a resolved one is shown and confirmed, and without a
terminal to ask (a script, the switcher) it is refused. `wts rm` also refuses a
worktree with uncommitted changes unless `-f`, and the current session — and it
finds the session's worktree and repository through the registry, so it works
from any directory, on a session of any repository.

### Branch resolution

When creating the worktree, `wts` picks the branch in this order:

1. **Existing local branch** → checkout.
2. **Existing branch on `origin`** → fetch, then checkout with tracking. This is the
   review case: you pick up existing work. Skipped offline or without `origin`.
3. **Otherwise** → new branch from the [base branch](#base-branch-detection).

The branch name is the layout's [branch prefix](#layouts) followed by the session
name. To review an origin branch by its exact name, use a layout without prefix,
such as `default`.

In case 3 the branch is created with `--no-track`. Otherwise, with a remote base
(`origin/main`, which `prefix+: wts` uses), git would make the new branch track the
base: `git status` would say "behind origin/main by 47" — which an agent reads and
acts on —, `git pull` would merge the base, and `wts gc` would never see the remote
branch disappear.

### Starting from a phrase

```sh
wts csv-export "the export times out above 10k rows"   # name given: instant
wts "the export times out above 10k rows"              # name proposed: export-timeout-large-rows
wts "the export times out above 10k rows" sentry       # layout after the phrase
```

A **phrase** is an argument containing a blank, in first or second position — no
session, branch or layout name contains one. It is removed from the positional
arguments (layout and context keep their places), then the Claude pane starts with
`claude "<phrase>"`, and the phrase is stored in the registry, where it fills the
SUBJECT column until Claude names the conversation.

**Without a name**, `wts-name` asks Claude Haiku for a 2–4 word kebab-case slug
(3 to 15 s). The call is isolated: `--safe-mode`, hooks disabled, no MCP server, no
tool, no transcript, run outside any worktree. **Ctrl-C** while it runs does not
abort the creation: it takes the name derived from the phrase, and says after
how long. Past `WTS_NAME_TIMEOUT`, without
`claude`, with `WTS_NO_LLM=1`, or when the answer is not a name, the name is derived
locally from the phrase and a warning on stderr says which of those happened — an
unrecognized `WTS_MODEL` included, which `claude` answers in prose rather than with
a failure.

**A proposed name is always unique.** Otherwise branch resolution would silently
check out another session's branch. It gets `-2`, `-3`… until it is free
everywhere: worktree folder, registry, tmux session, local or remote branch. A name
you give yourself keeps the normal behavior, checkout of an existing branch included.

**Quote the phrase.** `wts fix the export` splits it and takes `the` as a layout —
the error message says so. In the tmux prompt, an apostrophe needs quotes too:
`wts "don't cache the header"`.

## Agent state

`wts ls` and the switcher show the Claude Code agent running in each worktree. The
data comes from `claude agents --json`, joined on the agent's `cwd` being *inside*
the worktree, so `WTS_SUBDIR` keeps working.

| Shown      | Source                             | Meaning                               |
|------------|------------------------------------|---------------------------------------|
| `blocked`  | `state: blocked` / `status: waiting` | waiting for a permission or an answer |
| `working`  | `status: busy` / `state: working`  | turn in progress                      |
| `idle`     | `status: idle`                     | turn finished, prompt available       |
| `done`     | `state: done`                      | background session finished           |
| `failed`   | `state: failed`                    | the turn failed                       |
| `stopped`  | `state: stopped`, or no tmux session | session stopped, or `wts stop`ped: the switcher shows it for a dead tmux session |
| `stuck?`   | stale guard                        | says `working`, but the pane is frozen |
| `-`        | no agent found                     | worktree without a Claude session     |

The **stale guard** hashes the agent's pane on every refresh: an agent reported as
`working` whose pane has not changed for `WTS_STALE_AFTER` seconds (10) is shown as
`stuck?`. Without it, a `Ctrl-C` leaves a session "working" forever.

Sessions are sorted by what needs a human first: `stuck?`, `blocked`, `failed`,
`idle`, `working`, then the rest — and among equals, the one waiting longest.
`wts status --json` exposes the same data (`agent_state`, `stale`, git
counters, tmux state) for scripts, plus `agent_since` (the epoch of the event
that put the agent in its state), `agent_waiting_for` (the permission or the
question) and `agent_source` (`agents` or `events`, see below).

**The agent's own events.** `claude agents` says what state an agent is in, not
since when nor what it is waiting on. The agent knows, and Claude Code says it
through its hooks: `wts setup claude --install` puts `wts-hook` on
`UserPromptSubmit`, `Stop`, `Notification` and `SessionEnd`, and each one
writes a row to the `agent_events` table (kept a week). The poll remains the
word on the state; the events date it — the prompt for `working`, the
notification for `blocked`, the stop for `idle` — and supply the question.
When claude cannot be asked, or does not list the agent, the last event decides
the state, unless it is an end or older than twelve hours. Outside a wts
session the hook is silent, and it never prints on stdout: Claude Code would
add a `UserPromptSubmit` hook's output to the conversation.

## When an agent needs you

Opening the switcher is a poll. The hooks above make it a push: on a
`Notification` (a permission to grant, a question to answer) and on a `Stop`
(the turn is over), `wts-hook` rings the pane's bell — tmux flags the window,
and a theme that draws flags shows it — and posts a desktop banner that names
the wts session: *wts: auth-form needs you — Bash: rm -rf dist*, or *wts:
auth-form is done — turn finished in 4m12s*. Both are skipped when the pane is
already under your eyes: the session attached, the window active and, on
macOS, a terminal in front.

The banner goes through `terminal-notifier` when it is on your `PATH` (or named
by `WTS_NOTIFIER`) — a click on it switches the tmux client to the session —
else through macOS's own notification, else `notify-send`. `WTS_NOTIFY=0`
turns bell and banner off, `WTS_NOTIFY=bell` or `banner` keeps one. If you had
wired a notifier of your own on these hook events, this replaces it: remove
yours, or you will hear both.

The tmux status line carries the count, from the snippet `wts setup tmux`
prints: `wts: 2 blocked · 1 idle`, and nothing at all when nobody needs you.
`prefix+a` goes to the agent that has waited longest and says why in the status
line: *wts: auth-form — blocked 4m: Bash: rm -rf dist*.

## Where each session stands: `wts brief`

```
auth-form  idle  feature/auth-form  +322/-0 ^4  PR #42
  done: server-side email validation before sending
  next: decide the wording of the rate-limit error
```

For each session whose worktree exists, in `wts ls` order, `wts-brief` gathers
facts without calling anything: git (commits unique to the branch, excluding both
`<base>` and `origin/<base>`; delta; uncommitted changes), the agent state, and the
worktree's Claude transcript (title, PR link, your last message, the tail of the
agent's messages, the starting task). Claude Haiku turns them into two lines, with
the same isolation as naming, `WTS_BRIEF_JOBS` calls at a time. Before it starts,
one line says what it is about to cost: `→ 3 haiku call(s), 4 at a time, 2 from
the cache`.

Each summary is **cached** in the state database (table `briefs`), keyed on HEAD,
uncommitted changes and the transcript's size and date: while nothing moved,
`wts brief` answers instantly. The transcript used is the live agent's, else the
most recent one of the worktree — never one older than the session, which would
belong to a previous session of the same name. Without `claude`, with
`WTS_NO_LLM=1`, or when the answer is malformed, the raw facts are shown, under the
reason the summary is missing. The model is never called by `wts ls` or the switcher.

### Tokens and cost

```
$ wts ls --wide
SESSION      AGENT    BRANCH       DELTA        DIRTY  TMUX     TOKENS  COST    MODEL     SUBJECT
auth-form    idle     auth-form    +322/-0 ^4   no     running  13.6M   $5.64   opus-5-5  Server-side email validation
rate-limit   working  rate-limit   +80/-2 ^1    yes    running  2M      $1.95   opus-5-5  Rate-limit the public API
```

`wts brief` also sums what each session's agents consumed: `message.usage` of
every transcript of the worktree no older than the session — the one after each
`/clear` and each subagent's included, every message counted once although
Claude Code repeats its usage on each of its records. Tokens per model go into
the `usage` table; nothing calls the model for it, so `WTS_NO_LLM=1 wts brief`
counts too, and an unchanged transcript is not read again. `wts rm` and `wts gc`
take a last count at teardown, and the rows stay with the archive.

`wts ls --wide`, `wts status --json` (`usage`), `wts log` and `wts task show`
read that table: never a transcript, so the numbers are as of the last
`wts brief` or teardown, and `-` before the first. **COST is the API list
price** of those tokens (cache writes at 1.25x or 2x input, reads at the
model's cache price, fast mode at 2x), computed when it is read from the table
in `usage_cost_sql` (`libexec/wts/wts-db.zsh`): it is what the work would cost
on the API, not what a subscription bills. A model that table does not know
counts its tokens but not their price, and the cost then reads `~$`.

> **Privacy.** `wts brief` sends to the model, through your own `claude -p`: the
> branch's commit log and diff stats, the session's starting prompt, your last
> message to the agent, and the tail (about 1,500 characters) of the agent's recent
> messages. `wts "<phrase>"` sends the phrase. Set `WTS_NO_LLM=1` to never call the
> model.

## Session switcher

`prefix+s` opens an fzf popup: sessions sorted by urgency, with agent state,
branch, git delta and a live preview of the agent's pane. **The keys are written
under the list**, so there is nothing to remember: one line by default, and `?`
unfolds the whole table — the tmux bindings included, since those are the ones
you cannot press from inside the popup. `enter` switches, `ctrl-x`
stops the selected session (`wts stop`, after a y/N prompt: its tmux session
closes, the worktree, the branch and the registry entry stay, the popup stays
open and the row reads `stopped`), `ctrl-d` removes it entirely (`wts rm`, after a y/N prompt that names
the session and its agent state), `ctrl-o` opens the branch's
pull request on GitHub (`wts pr`, through `gh pr view --web`: without a PR the popup
says so and stays open; without `gh` the key is neither bound nor listed),
`ctrl-e` attaches a [context document](#context-documents-wts-doc) to the session
and tells its agent (`wts doc use`, picker included), `ctrl-t` pulls a
[task](#the-work-you-have-not-started-yet) in from Things,
`ctrl-f` / `ctrl-b` scroll the preview by half a page, `ctrl-r` reloads. The
current session is never stopped from the popup, which it would close. tmux
sessions unknown to wts are listed after, and `ctrl-x` works on them too.

The footer is sized to the list: a narrow popup keeps the keys you press most
and drops the rest, `?` still shows them all. While you are filtering the list,
`?` is typed into the query instead (the AGENT column has `stuck?` in it), and in
reply mode the footer shows what `enter` and `esc` do there. `wts keys` prints
the same table in a terminal, from the same source, for when the popup is not
open. The footer needs fzf 0.65 or later; older versions keep the plain switcher
and `wts keys`.

The list is a table **sized to the popup**: the session and branch columns take
the width of their longest value, capped so that every column stays visible, and
a cell too long for its column is cut with `…` rather than pushing its row out
of line. `*` after a name marks the session you came from, as tmux marks its
current window; `@` at the start of SUBJECT marks a session that serves a
[task](#the-work-you-have-not-started-yet). The preview takes the
right half; its first line is the agent's state, for how long, and the question
it waits on when there is one (`blocked 4m: Bash: rm -rf dist`). Under it, dimmed,
what the session already said about itself: the cached `done:` / `next:` of
`wts brief` with its age, and the last two notes its agent left with `wts db set`
— from the database, never a model call, and dropped on a popup too short to
spare the lines. Then the pane itself.

`tab` **answers the agent without leaving the popup**: the prompt becomes
`reply to <session>>`, what you type no longer filters the list, and `enter` sends
the line to the agent's pane followed by Enter — a number for Claude's numbered
questions and permission prompts, a sentence for the rest, nothing at all for a
bare Enter. The preview keeps refreshing, so the agent's reaction shows up in
place; `esc` or `tab` brings the list back (`enter` switches again). The reply
stays pinned to the session you pressed `tab` on, even if the list re-sorts under
the cursor, and `ctrl-d` / `ctrl-x` are disabled meanwhile. While the agent column shows `-`,
wts does not know the agent's pane yet and the reply goes to the session's active
pane. Needs fzf 0.45 or later; older versions keep the plain switcher.

The popup is **drawn at once**, on a list built from the registry and tmux alone —
no git, no agent call. fzf then swaps in the agent states (`load`, then
`reload-sync` of a pass that asks Claude and tmux but not git: tens of
milliseconds), and the first refresh brings the git columns. Until then the
columns show `-`: an agent state one refresh old is worse than no state at all.

The list and the preview **refresh every 2 s** (`WTS_SWITCH_REFRESH`, `0` for a
static list). fzf has no timer event, so the refresh goes through `--listen`: a
background poller pushes `reload-sync(...)+refresh-preview` to fzf's unix socket.
`reload-sync` avoids a blinking empty list and keeps the cursor and query. The
poller never replaces a pass still running, and waits at least as long as the
last pass took before starting the next one: on a large repository where a pass
takes seconds, the list fills after one pass and the preview keeps refreshing in
between. The poller dies with the popup. Without `curl`, or when the socket path
exceeds the 104 bytes of `sun_path`, the switcher silently falls back to a static
list. The cursor is kept by index: if a session changes urgency, the highlighted
line can change session under you.

The **scroll offset lives outside fzf**, in a small file the preview command reads:
every `refresh-preview` resets fzf's own preview offset, so native scrolling would
be undone within two seconds. At rest the preview follows the end of the pane;
`ctrl-b` goes back through the real tmux history (`WTS_SWITCH_SCROLLBACK` lines).
Moving to another session returns to live. Trade-off: `ctrl-f` / `ctrl-b` no longer
move the cursor in the query — the arrow keys do.

The preview window is **as wide as the agent's pane**, up to the right half it
starts with. The preview is a raw `capture-pane`, text at the pane's width: with
the editor as the main pane, a 56-column agent pane drawn in a 110-column window
left half of it blank while the list was squeezed to 76 columns and lost the
subject. The width follows the highlighted session (`focus` → `transform` →
`change-preview-window`, fzf 0.46 or newer; older versions keep the half-width
window). The list is laid out for the other half, so a wider pane is truncated on
the right rather than pushed into the list.

### The work you have not started yet

![a task given a note and a context document, wts task show listing what it now carries, the switcher showing that task as a row with a count of its context, its preview holding the note and the document, tab typing another note straight onto it without leaving the popup, and enter starting a session on the task whose agent opens on the context file](docs/tasks.gif)

Under the sessions, the popup lists the **open tasks** — the other half of the
question it answers — those with no session first. A task row reads `task` in the
AGENT column, and `N ctx` in DELTA: how many documents, links and notes it already
carries, so you can see at a glance whether a piece of work is ready to start. A
task some sessions already serve stays listed, with `N session(s)` in SUBJECT:
`enter` on it starts one more, for a second attempt next to the first.
The preview is the task itself — title, status, the sessions started from it
(live ones with their agent's state, then the last three finished ones as
*previous attempts*: outcome, PR, and what was delivered, what resisted, how it
was resolved, what was abandoned, from their retrospectives), the
notes you kept on it, its links, its documents — which makes the popup the place you decide *what* to do,
not only *where* to go back to.

On a task row:

- **`enter` asks what to do with it**, on a second screen in the same popup:
  - **new session from a prompt** — pre-filled with the title; the agent opens on
    it and wts names the session from it (`wts-fresh "<prompt>" --task <id>`);
  - **new session from a branch name** — pre-filled with a name derived from the
    title; a `feature/` typed by habit is dropped, wts adds its own prefix
    (`wts-fresh <name> --task <id>`);
  - **attach to a session** — for work that started before the task was written
    down (`wts task link`), then switches to it. The agent already running sees
    the task at its next `/clear`.

  Creation goes through `wts-fresh`, the same path as `prefix+g`: the branch is
  cut from a freshly fetched base and it refuses outside a repository. `esc` goes
  back to the list.
- **`tab` notes on it**, the way `tab` replies to an agent: the prompt becomes
  `note on <task>>` and `enter` appends the line to the task's notes. This is the
  fastest way to put something where the next session on this task will find it.
- **`ctrl-e` attaches a document to the task** rather than to a session, so every
  later attempt at it inherits the document.
- **`ctrl-d` closes it**, after a y/N prompt (`wts task done`): the task leaves
  the list for good, its notes, documents and past sessions stay. Only a task wts
  holds by itself — a Things task is completed in Things, and leaves the list at
  the next `wts task ls`, the one command that reads Things again.


![ctrl-t typing a task into the switcher, the new row selected with its preview, enter on it offering a new session from a prompt or a branch name or attaching it to a session, a session created from the branch name feature/migration-guide, and a second task attached to an existing session](docs/new-task.gif)

Anywhere in the list, **`ctrl-t` creates a task**: the prompt becomes
`new task>`, you type the title, `enter` creates it (`wts task new`) and puts the
cursor on it — ready for `tab`, `ctrl-e` or `enter`. On an empty title, `enter`
pulls one in from Things instead (`wts task add`), where Things is installed. The
switcher itself only ever reads its own database — one query, no Things, no git,
no model, because it runs every 2 s.

A task already being worked on stays listed, after the ones still to start, with
`N session(s)` in SUBJECT — `enter` on it is how a second session starts — and
its sessions carry the `@` in theirs. Ten tasks at most, most recently touched
first (`WTS_SWITCH_TASKS=<n>`, `0` to hide them).

`prefix+a` jumps straight to the agent that needs you (`stuck?`, `blocked`,
`failed`, `idle`) and has waited longest, without a popup, and says why in the
status line; pressing it again cycles through them.

Tip, not included in the snippet: `choose-tree` assigns jump keys to its lines, so
`j` / `k` select a line instead of moving once enough sessions are open. This keeps
jump keys to digits:

```tmux
bind w choose-tree -Zw -K '#{?#{e|<:#{line},10},#{line},}'
```

## Creating from tmux

`prefix+:` opens tmux's command prompt; type `wts` followed by the **usual `wts`
arguments** (`prefix+g` pre-fills it). You get the prompt's history for free.

```
wts auth-form
wts fix-ABC123 sentry "timeout on /api/v2"
wts "the PWA header hides the profile button"
```

The command goes through `wts-fresh`, which adds two guarantees:

1. **outside a git repository it refuses** — nothing is created;
2. **the branch is cut from a freshly fetched `origin/<default>`.** If the fetch
   fails (offline, no `origin`), it **aborts**: a worktree started from a stale base
   is exactly what it exists to prevent. Offline, `wts <name>` from a shell still
   works, on the local base.

The default branch is detected, never hardcoded: `WTS_BASE_BRANCH`, local
`origin/HEAD`, `git ls-remote --symref origin HEAD`, then `origin/main` and
`origin/master`. A missing `origin/HEAD` is restored along the way. The local base
branch is fast-forwarded when it is safe — a bonus, never blocking.

Run from inside a wts session, creation is attached to the main repository, not the
current worktree (no nested worktrees). If the branch already exists, it is checked
out and the base is not used; nothing is ever rebased. tmux splits the arguments
itself, so quote contexts with spaces; an unclosed apostrophe swallows the rest of
the line, and `wts-fresh` says so. The new window does not see the calling pane's
environment: when the repository has an `.envrc` and direnv is installed, `wts`
runs through `direnv exec`. A phrase without a name is named in the background
while the fetch runs.

`ls`, `status`, `brief`, `restore`, `stop`, `pr`, `doc`, `db`, `log`, `retro`,
`task`, `layouts`, `keys`, `doctor`, `setup`, `help` and `version` are passed
through without fetching; `gc` and `rm` run from the main repository. When `wts`
fails, the window stays open on its message until a key is pressed.

## Batch creation

```sh
wts new cors rate-limit csv-export       # default layout
wts new -p sentry ABC123 DEF456
wts new "rate-limit the API per key" "export as CSV"   # names proposed one by one
```

`wts a & wts b & wts c` does **not** work: the normal flow ends with
`exec tmuxinator start`, so the first call replaces the process. `wts new` starts
each session detached, then attaches to the first. Creations are sequential: in
parallel, two similar phrases could get the same name.

## Context documents: `wts doc`

A technical spec in Notion, an architecture page, a file of conventions on disk:
the same context, pasted by hand into every new agent. `wts doc` keeps a small
library of those documents — fetched once, cached — and `--doc` attaches one to a
session.

```sh
wts doc add https://www.notion.so/Payments-architecture-abc123   # once, ~10-30 s
wts auth-form "limit the rate per key" --doc payments-architecture
wts auth-form "limit the rate per key" --doc    # pick one from the library
wts fix-typo "a comma too many"                 # nothing attached
```

**Nothing is attached unless you ask for it.** There is deliberately no
per-repository pinning: several projects run at once, and the document that
matters to one worktree is noise in the next.

`--doc` is repeatable and takes a slug of `wts doc ls`, a URL, or a path. It
**always consumes the next argument** — a bare `--doc` at the very end of the
line opens an fzf picker instead. `wts <name> <layout> --doc <slug>` is the
unambiguous order, and `--doc=<slug>` works anywhere.

### Where it lands

wts writes `<worktree>/.wts/context.md` — every attached document one after
another, each with its title, source and fetch date — and the Claude pane starts
on `claude "Read @.wts/context.md first, …"`. The folder carries its own
`.gitignore` containing `*`, so it never appears in `git status`, never makes a
worktree look dirty to `wts gc`, and goes away with the worktree.

Layouts receive the path in `WTS_DOC`, relative to the pane's working directory
(Claude Code resolves an `@` reference from the pane's cwd). A layout of your own
picks it up with the few lines the built-in `default.yml` uses.

### Fetching: whatever this machine can read

A URL is fetched by a headless `claude -p` started with **this machine's own MCP
configuration**, and the model uses whatever tool can read it. Nothing about a
particular provider is hardcoded, on purpose: the same page sits behind a Notion
connector on one machine and behind a gateway with entirely different tool names
on another, and both work with no configuration.

The allow list is built per server from `claude mcp list` (cached for a day —
the CLI refuses a bare `mcp__*` wildcard in an allow rule), plus `WebFetch`, with
every write-shaped tool denied. `WTS_DOC_TOOLS='mcp__<server>__*'` pins it when
that enumeration is noisy or when only one connector should ever be used.

A local markdown file never calls the model at all, and is re-read on every attach.

**When nothing can read it, the document degrades to a pointer:** the context
file carries the URL and asks the agent to fetch it itself. The agent in the pane
has your full set of connectors and often succeeds where the headless call could
not. The same happens offline, without `claude`, or with `WTS_NO_LLM=1`.

### Freshness

`wts doc add` fetches. On attach, a URL older than `WTS_DOC_TTL` (24 h) is
fetched again, under a timeout, falling back to the cache when the network or the
connector is missing — so an attach is never blocked by them. `wts doc sync`
refreshes on demand. A fetch that comes back a fraction of the cached size is
refused and the cache kept (`--force` accepts it): silently replacing a good spec
with a stub is the worst thing this could do.

### Attaching to a session already running

```sh
wts doc use payments-architecture             # from inside the worktree
wts doc use payments-architecture auth-form   # or by name, typo-tolerant
```

The context file is rewritten and the reference is sent into the agent's pane, so
an agent already working picks it up without being restarted. In the switcher,
`ctrl-e` does the same on the highlighted row, picker included.

```
wts doc add <url|path> [--name <slug>] [--force]   add a document
wts doc ls                                         the library
wts doc show <slug>                                what will be injected
wts doc sync [<slug>...] [--force]                 fetch again
wts doc forget <slug>                              remove it from the library
wts doc use <slug> [<session>]                     attach to a running session
wts doc tools [--refresh]                          what the fetch may use
```

The library itself is `~/.config/wts/docs.json` (`WTS_DOCS_PATH`), four keys per
entry and meant to be edited by hand; the fetched content is a cache, in the
state database (table `doc_cache`).

> **Privacy.** `wts doc add` and `wts doc sync` send the document's URL to the
> model through your own `claude -p`, which then reads the page with your own
> connectors. The content is written in clear text inside the worktree. Set
> `WTS_NO_LLM=1` to never call the model — documents then stay pointers.

## Garbage collection

```sh
wts gc              # dry run: lists, deletes nothing
wts gc --apply      # does it
wts gc --no-fetch   # without contacting the remote (offline)
wts gc --all        # every repository that has a session, from anywhere
wts gc --all-branches   # every local branch, not only those of wts sessions
```

**Only what wts made.** A branch is looked at when a session of this repository
had it — a live one, or a finished one in the archive — and a husk folder when it
bears such a session's name. A local `develop` you merged by hand, a worktree you
made yourself, a folder someone else keeps under a shared `WTS_WORKTREES_BASE`:
the dry run counts them ("not made by a wts session, not looked at: 3") and
leaves them alone. `--all-branches` is the scope before 1.6, every local branch
and every folder without `.git`, for a repository where all of them are
disposable.

**What `--apply` costs is said before it.** Each session it archives gets a
retrospective, one model call each (`WTS_MODEL`, `WTS_RETRO_JOBS` at a time,
after every deletion): the dry run says how many, and `--no-retro` skips them
(`wts retro` writes them later).

**The remote is the source of truth.** `wts gc` starts with
`git fetch --all --prune`, then compares against `origin/<base>` rather than a local
base that may lag behind. Six categories, limited to the current repository and
to what wts made —
`--all` runs the same collection once per repository in the registry, each from
its main worktree:

1. **Husk folders** in `<repo>-worktrees/` — `git worktree remove` leaves git-ignored
   files behind, so a folder without `.git` remains after each `wts rm`.
2. **Worktrees on a dead branch** — removed with their tmux session and branch.
3. **Dead branches** without a worktree — their content is entirely in the base.
4. **Orphan branches** — the remote branch is gone but the content is **not** in the
   base. Never deleted automatically: listed with their commit count, your call.
5. **Orphan registry entries** whose worktree disappeared.
6. **Stale `index.lock`** — a git process killed mid-operation leaves one behind, and
   from then on every write in that worktree fails with `Unable to create
   '.git/worktrees/<session>/index.lock': File exists`. Nothing reports it, so the
   worktree looks fine until the next `git add`.

**Why not `git branch --merged`.** It only recognizes merges by ancestry. A pull
request merged by **squash** or **rebase** rewrites the SHAs, so the branch is never
an ancestor of the base and piles up forever. `wts gc` also compares **patch-ids**
(the test behind `git cherry`, with the base hashed once for all branches rather
than once per branch): a branch whose every commit has an equivalent in the base is
entirely present in it, whatever the merge method, and is deleted with
`git branch -D`. A deleted remote branch is read from `%(upstream:track)` ==
`[gone]`, which only `--prune` reveals.

**Safety rules:**

- Only `<repo>-worktrees/` is scanned for husks, and a folder with a `.git` is never
  proposed.
- A branch with no commit since it was created is never collected: a fresh session
  whose agent has not committed yet looks "merged" to git.
- A worktree with uncommitted changes, or whose agent is busy (`working`, `blocked`,
  `stuck?`), is left in place and listed as such.
- The current tmux session is never killed.
- An `index.lock` is only removed once it is empty, older than `WTS_LOCK_STALE_AFTER`
  (5 min) and held by no live process: deleting a lock somebody owns would corrupt
  their index.

## The work journal: `wts log`

![wts task link labelling a finished session, wts ls showing the marker it adds, wts gc announcing what it would archive and then archiving it, the retrospective written by Claude, and wts task ls and wts log reporting what survived the teardown](docs/journal.gif)

```sh
wts log                             # the last 180 days, as JSON
wts log --since '-6 months'         # or an ISO date: --since 2026-04-01
wts log --brief                     # titles, outcomes, retros — without the bulk
wts retro                           # write the retrospectives gc could not
```

**`wts gc --apply` and `wts rm` now archive what they tear down.** They used to do
the opposite: `registry_del` and gc's closing transaction deleted the session row,
its brief and its notes — so the moment a piece of work became tellable was the
moment wts forgot it. What is kept, per finished session: the phrase it started
from, the branch and its base, the outcome (`merged`, `squashed`, `remote-deleted`,
`removed`, `abandoned`), the pull request, the commit subjects, the paths touched,
the diffstat, the notes the agents left each other, the last brief — and a
four-line retrospective.

**Why a retrospective and not just a pointer to the conversation.** Claude Code
deletes transcripts after 30 days by default. On the machine this was built on:
275 transcripts, 148 MB, **none older than 30 days**. A self-assessment looks six
months back, so by the time you need it the only trace of *how* the work went is
already gone. `wts gc --apply` therefore asks Haiku, once per finished session and
while the transcript is still there, for four lines:

```
delivered: BalanceMovement and its 47 collaborators moved into packs/banking
resisted:  the Packwerk boundary check failed on two circular references
resolved:  inverted the dependency with an event rather than a privacy exception
abandoned: dropping the deprecated alias in the same PR — deferred a release
```

`resisted` and `resolved` are the parts a task title can never carry, and they are
read mostly from **your own corrections to the agent** — "no, that breaks
idempotency", "revert that" — which is the only place friction is recorded.

wts also keeps a gzipped copy of the transcript (`~/.local/state/wts/transcripts/`,
about 2–5 MB per semester), so `wts log` can tell you whether drilling into the raw
conversation is still possible: each session carries
`transcript.available`, tested at export time rather than promised.

Each session also carries `usage` (input, output, cache writes and reads, per
model, and `cost_usd` at API list prices; see [Tokens and cost](#tokens-and-cost)),
and each work item the total of its sessions: what a task cost over all its
attempts. `null` where nothing was ever counted.

### A task is where the context lives

A session lasts days and dies at the merge; the task lasts months. So the task is
where the material belongs — and `wts <name> --task <id>` hands **all** of it to
the new session:

```sh
wts task add                        # pick a Things task; it joins wts's list
wts task note "the spec moved to the new Notion page"   # from inside a worktree
wts task edit                       # longer context, in $EDITOR
wts task doc api-spec               # a document every session on this task gets
wts audit-trail --task <id>         # a session that opens on all of the above
wts task done                       # a local task is finished: off the list
```

A task stays on the list, and comes back after each session on it is removed,
until it is closed: in Things for a Things task, with `wts task done` (or
`ctrl-d` on its row) for one wts holds by itself.

`note`, `edit` and `doc` default to the task of the session you are in, so
inside a worktree they need no id. What they write is wts's own: Things stays
read-only, and a note you add here is **not** overwritten the next time wts
refreshes the task from Things — which a column on the task would have been.

The first `wts task add` on macOS 15+ makes the system ask whether your terminal
may *access data from other apps*: Things keeps its database in its own
container. Say yes once and wts remembers that it can read it; say no and it
stops offering Things at all — `wts task new "<title>"` keeps working either
way, on a task wts holds by itself, and `wts task add` is still how you try
again once you have changed your mind in System Settings. Nothing else ever
opens Things: not `wts ls`, not the switcher, not a hook.

Four channels carry it into the session, and they are four because each one
fails differently:

1. **The agent's opening prompt** is the task title, when you typed no phrase.
   `wts fix-audit --task <id>` used to start the agent on nothing at all.
2. **The documents on the task** are attached like `--doc` ones. Already fetched,
   so creation pays nothing.
3. **`.wts/context.md` opens with the task**: its title, status, your notes,
   its *previous attempts* (the last three archived sessions with their outcome,
   PR and retrospective, so a retry starts where the last one stopped), its
   links, before the documents. This is the only channel the agent reads *before
   its first turn*.
4. **The `SessionStart` hook repeats it** — and it is the only one that comes
   back, because Claude Code re-runs the hook after `/clear`, `/compact` and a
   resume, while a prompt and a file are read once.

**The links you keep in a task become context too.** `--task` reads the URLs out
of the task's notes — the Notion page, the meeting minutes, the Slack thread — and
attaches them as [context documents](#context-documents-wts-doc). They are
recorded as **pointers**, not fetched: a task carries one to three links, the fetch
model is sonnet with a 90 s cap, and paying that at creation would put minutes in
front of a starting agent. A pointer is also likelier to work — a Slack permalink
or a private Notion page is exactly what the sandboxed fetch cannot read and the
agent in the pane can. `wts doc sync` fetches them later, at your pace. A document
you attached with `wts task doc` wins over a pointer to the same page.

All of it survives the teardown: the notes and documents belong to the task, not
to the session that was removed with it.

**Where the model is called, and where it is not.** Only in `wts gc --apply`, and
only after every destructive step has finished and been reported — so a timeout, a
missing `claude` or a Ctrl-C there costs nothing but text, which `wts retro` writes
later from rows already in the database. `wts rm` never calls it: it is synchronous
with a human waiting, and often used on work being abandoned. `wts gc --no-retro`
and `WTS_NO_LLM=1` skip it; the facts are archived either way.

**A dry run still writes nothing.** `wts gc` announces `To archive (kept for wts
log): 3 session(s)` and stops there.

**Privacy.** This is the most sensitive thing wts produces: prompts, commit
subjects, file paths, agent notes and a full transcript copy. The database is
`chmod 600`, but `wts log` prints all of it on stdout. `--no-notes` drops the free
text, `--brief` drops the bulk, `WTS_ARCHIVE_TRANSCRIPT=0` stops the transcript
copy, and `WTS_NO_ARCHIVE=1` stops the capture altogether.

## Persistence and restore

A reboot kills the tmux server, **not the worktrees**. `wts` records every session
in the `sessions` table of its state database,
`${XDG_STATE_HOME:-~/.local/state}/wts/wts.db`:

```
$ wts db sql "select * from sessions where name = 'auth-form'" --json
[{"name":"auth-form","profile":"feature","repo_root":"/home/me/code/myapp",
  "worktree":"/home/me/code/myapp-worktrees/auth-form","branch":"feature/auth-form",
  "subdir":"","context":"","prompt":"validate the email server-side before sending",
  "docs":"[]","created_at":"2026-09-05T15:12:41Z"}]
```

The same database holds the `wts brief` cache, the fetched documents, the stale
guard's pane hashes and the agents' notes. It runs in WAL mode: the switcher and
any number of agents read while one process writes, and a second writer waits its
turn instead of overwriting the first — the lost update the old JSON file allowed.

`wts restore [name...]` replays `tmuxinator start --no-attach` for every registered
session missing from tmux whose worktree still exists — all of them without
arguments. It never attaches: restoring eight sessions should not steal your
terminal. `wts ls` purges entries whose worktree is gone, after archiving what
the registry knew about them (outcome `unknown` in `wts log`). This is a **declarative
replay**, not a snapshot like tmux-resurrect: a wts session is fully described by
its name, layout and context, so replaying the layout is more faithful.

`wts stop <name>` leaves the same state on purpose, without a reboot: the tmux
session is killed, everything else stays, and `wts restore <name>` replays it.

During `wts restore`, layouts see `WTS_RESTORE=1` and skip heavy commands —
otherwise eight sessions mean eight `claude` and eight dependency installs at once.
The Claude pane is not empty for all that: the command is **pre-filled** on the
pane's zsh command line (`print -z`), press Enter to run it. When the hooks
recorded the agent's conversation and its transcript still exists,
`WTS_RESUME_ID` carries its id and `claude --resume <id>` is proposed — the
agent's own conversation, where `--continue` takes the most recent one in the
directory, which may be a side chat. When only a conversation for the pane's
directory exists, `WTS_RESUME=1` and `claude --continue`; otherwise plain
`claude`, since both would fail. The leading space keeps the command out of
your history (`histignorespace`).

```erb
<% claude_cmd =
    if restore
      if ENV['WTS_RESUME_ID'].to_s =~ /\A[0-9a-f-]+\z/
        %Q{" print -z 'claude --resume #{ENV['WTS_RESUME_ID']}'"}
      elsif ENV['WTS_RESUME'].to_s == '1'
        %q{" print -z 'claude --continue'"}
      else
        %q{" print -z claude"}
      end
    elsif task.empty?
      'claude'
    else
      "claude #{task.shellescape}"
    end %>
        - <%= claude_cmd %>
```

`wts restore` is manual. To run it after a reboot, add to `~/.zshrc` — it only fires
once, on a cold tmux server:

```sh
if [[ -z "$TMUX" ]] && ! tmux has-session 2>/dev/null; then
  wts restore >/dev/null 2>&1
fi
```

## Agents share state: `wts db`

Agents running in parallel on one repository used to be blind to each other: two
of them could rework the same file, or one could change an API another was
building on, and only you knew. wts already knows every session, so it shares
that knowledge with the agents themselves.

**Every agent is told, automatically.** `wts setup claude --install` adds a
Claude Code `SessionStart` hook (user-wide, in `~/.claude/settings.json`), the
four event hooks of [When an agent needs you](#when-an-agent-needs-you), a
`PostToolUse` hook on edits, the permissions for wts's read-only verbs and the
agent's own notes (`wts ls`, `wts status`, `wts task ls/show`, `wts doc ls/show`,
`wts log`, `wts db`, `wts wait`, `wts tail`… never `rm`, `gc`, `stop`, `send` or
a creation) so no agent starts its work blocked on a prompt, and the wts skill.
In a wts session the `SessionStart` hook puts a short block at the top of the
agent's context — again after `/clear`, `/compact` and a resume:

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
- rate-limit (feature/rate-limit): rate-limit the public API per key — brief, 2h ago: done: … / next: …
- csv-export (feature/csv-export): export users as csv

Latest notes they left:
- rate-limit/api-contract (2026-09-28T09:12:03Z): /login now answers 429 with Retry-After

Files you and another session have both edited:
- src/api/limits.ts (also: rate-limit)

If you edit a file one of them also edits, wts tells you then. When your change
affects them (a migration, a shared model, an API contract), leave one line:
  wts db set <key> "<one line>"
Everything else — their notes, live states, sending to or waiting for another
agent — is in the wts skill (or: wts help).
```

The task section is there when the session serves a [task](#a-task-is-where-the-context-lives),
with how and when the link was made: a session keeps the task it was created
for while the work moves on, and the agent can now tell. The rest is about the
sessions **of the same repository** — another repository's cannot collide with
this worktree, so they are not listed — eight at most, with their five latest
notes and the files both sessions have edited. An agent alone on its repository
gets one line instead. The task's own notes are cut at twelve lines. All of this
is re-read at every start, `/clear`, `/compact` and resume, so it is kept to
what can change what the agent does — the reference is the skill, loaded when
needed; `WTS_CONTEXT_QUIET=1` in the agent's environment keeps only the first
line and the task's title.

**The rest arrives when it happens.** Two hooks speak during the session, and
only when there is something to say:

- **At the start of a turn** (`UserPromptSubmit`): the notes the same
  repository's other agents left since this agent's last turn, five at most —
  a note written an hour after `SessionStart` used to reach nobody who did not
  poll.
- **After an edit** (`PostToolUse` on `Edit`, `Write`, `MultiEdit`,
  `NotebookEdit`): the first time the agent edits a file another session of the
  repository has edited too, the tool result says which session, on which
  branch, since when. Every edited path is recorded in the `touches` table,
  relative to the worktree, which is what makes the overlap exact.

Anywhere else — a Claude started outside wts — the hooks print nothing. They
read and write the database only: no `git status`, no model call, about 0.1 s.

**What an agent (or you) can do:**

```
wts db sql "<SELECT ...>" [--json]    read anything: sessions, briefs, notes, doc_cache...
wts db schema                         the tables
wts db notes [--all] [--json]         this session's notes, or everyone's
wts db get <key>                      one note of this session
wts db set <key> <value|->            write a note ('-' reads stdin)
wts db del <key>
wts db path
```

Reads cover every table. Writes cover **only `notes`**, keyed by the session the
command runs in — found from the tmux pane (`$TMUX_PANE`), else from the worktree
containing the working directory; `--session <name>` overrides it. `wts db sql`
opens the database read-only and in sqlite3's safe mode (no `.shell`, no
`ATTACH`, no `readfile`), so no query can damage the registry. `wts rm` and
`wts gc` drop the notes of the sessions they remove.

## Driving wts from an agent

An agent can do what you do in the switcher, from its Bash tool — which has no
terminal. Ask your Claude to "start three sessions on these tasks and tell me
when they are done", and with the skill installed it knows how:

```sh
wts "add a --json flag to wts brief" --json      # {name, branch, worktree, task, …}, detached
wts new -p default --json cors rate-limit        # several: an array
wts wait cors rate-limit --timeout 90            # 0 once neither is working, 1 on timeout
wts status --json | jq '.[] | {name, agent_state, agent_waiting_for}'
wts send cors "1"                                # answer the question it is blocked on
wts tail cors -n 3 --json                        # what it said last, from its transcript
```

- **Nothing waits on a terminal that is not there.** Without one on stdin, a
  creation never attaches (`--detach` says so explicitly): from an agent's pane
  it used to `switch-client` and move *your* terminal. Pickers and
  confirmations exit 2 and name what to pass instead (`pass its id (wts task ls
  --json)`), and Things is never read — macOS asks before another app's data is
  read, and an agent is not you (`WTS_THINGS_FROM_SCRIPT=1` lets a cron job).
- **JSON for every listing**, each with `"version": 1`, keys added and never
  renamed: `wts status --json`, `wts task ls --json`, `wts task show <id>
  --json`, `wts doc ls --json`, `wts doc show <slug> --json`, `wts brief
  --cached --json` (the last summaries, no model call), `wts gc --json` (the dry
  run's plan: what would go and why; never with `--apply`), `wts doctor --json`,
  `wts wait --json`, `wts tail --json`, and a creation's `--json`.
- **Exit codes**: 0 done, 1 failed (a session that did not come back, a wait
  that timed out, a refused send), 2 usage (an unknown option, a typo of a
  command, a picker with no terminal).
- **`wts send`** types into the agent's own pane — the one its hooks recorded
  from `$TMUX_PANE`, or the one the collector matched — and refuses when it does
  not know it. The switcher's reply mode and `ctrl-e` follow the same rule: they
  used to type into the session's active pane, the editor of the default layout.
- **`wts wait`** returns after `--timeout` (90 s by default, under the two
  minutes an agent's Bash tool gives a command): call it again to keep waiting.
  `--until blocked,idle` waits for those states only.

The skill (`wts setup claude --install` writes it, `wts doctor` checks it) is
this section and the commands above, for the agent: when to read, when to
delegate, and what to ask you before doing — `rm`, `stop`, `gc --apply`, and
anything that calls the model.

## Upgrading to 1.0

1.0 moves all of wts's state from files to one SQLite database. Nothing to do by
hand beyond upgrading, but here is what happens and how to check it.

1. **Upgrade**: `brew update && brew upgrade wts` (or `git pull && make install`).
   `wts --version` prints `wts 1.0.0`. `sqlite3` must be on the `PATH`: macOS
   ships it.
2. **Optional backup**: `cp -R ~/.local/state/wts ~/.local/state/wts.bak-0.x`
   (or under your `XDG_STATE_HOME`).
3. **Run any wts command** — `wts ls` will do. The first one imports the old state
   into `wts.db` and says so:
   `→ state imported into …/wts/wts.db (8 sessions; old file kept as sessions.json.migrated)`.
   Imported: the registry (`sessions.json`) and the fetched documents
   (`docs/*.md`). Dropped, and rebuilt on first use: the `wts brief` cache
   (`brief/`) and the stale guard's pane hashes (`panehash/`).
4. **Check**: `wts ls` lists the same sessions as before, and
   `wts db sql "select count(*) from sessions"` gives their number.
5. **Let the agents see each other**: `wts setup claude`, read it, then
   `wts setup claude --install`. Agents already running pick it up at their next
   `/clear`, `/compact` or restart.
6. **Scripts** that read `sessions.json` directly: switch to `wts status --json`
   (unchanged contract) or `wts db sql "…" --json`.

**Rolling back** to 0.4.3: reinstall it, then
`mv ~/.local/state/wts/sessions.json.migrated ~/.local/state/wts/sessions.json`.
Sessions created under 1.0 are missing from that file (their worktrees and
branches are untouched; `wts <name>` in the repository registers one again).

## Layouts

A layout is a [tmuxinator](https://github.com/tmuxinator/tmuxinator) project file
(ERB + YAML). `wts <name> <layout>` looks it up in this order:

1. `$WTS_LAYOUTS_PATH/<layout>.yml`, by default `${XDG_CONFIG_HOME:-~/.config}/wts/layouts/`
2. the built-in `<prefix>/share/wts/layouts/<layout>.yml`

A user layout shadows a built-in one of the same name; `wts layouts` lists what is
found, with paths. The built-in `default` layout opens `$EDITOR` next to Claude
Code, plus a shell window. tmuxinator is started with
`--project-config <file> --name <session>`, so your own `~/.config/tmuxinator`
projects are untouched.

```sh
mkdir -p ~/.config/wts/layouts
cp "$(wts layouts | awk -F'\t' '$1 == "default" { print $2 }')" ~/.config/wts/layouts/feature.yml
```

[`examples/layouts/`](examples/layouts) has two richer ones: `feature` (nvim, Claude,
dev servers, lazygit) and `sentry` (Claude starts investigating the issue id given
as context).

**Branch prefix.** A layout declares the prefix of the branches it creates in a
comment line, conventionally the first one; without it, the branch is the session
name.

```yaml
# wts: branch_prefix=feature/
```

`WTS_BRANCH_PREFIX` overrides it for one call, even when empty:
`WTS_BRANCH_PREFIX= wts login-flow feature`.

**Variables exposed to layouts**, readable in ERB with `ENV['…']`:

| Variable      | Value                                                            |
|---------------|------------------------------------------------------------------|
| `WTS_NAME`    | session name (given, or proposed from the phrase)                |
| `WTS_ROOT`    | absolute path of the worktree                                    |
| `WTS_WORKDIR` | `WTS_ROOT` + `WTS_SUBDIR` when set, else `WTS_ROOT`              |
| `WTS_CONTEXT` | remaining arguments, joined                                      |
| `WTS_PROMPT`  | the phrase of `wts "<phrase>"` (empty otherwise)                 |
| `WTS_PROMPT_FILE` | absolute path of a file holding that phrase (`.wts/prompt` in the worktree), empty without one |
| `WTS_RESTORE` | `1` during `wts restore`                                         |
| `WTS_RESUME`  | `1` during `wts restore` when a Claude conversation exists       |
| `WTS_RESUME_ID` | during `wts restore`, the id of the agent's own conversation when the hooks recorded it and its transcript exists |

Use `WTS_WORKDIR` for `root:` and `WTS_ROOT` for commands that must run from the
worktree root. Panes do not inherit the environment of `wts` (the tmux server is
already running): read variables in ERB, not in pane commands. To start Claude with
the phrase, copy the `claude_cmd` block of `default.yml`, which escapes it for the
pane's shell. Have the pane read the phrase from `WTS_PROMPT_FILE`
(`claude "$(cat <file>)"`) rather than type it: tmuxinator types the pane's command
before its shell is ready, and the terminal then keeps 1024 bytes of a line, so a
long phrase typed whole loses its end and Claude never starts. Keep layout files **ASCII**, comments included: without a UTF-8
locale (`LANG=C`), Ruby refuses to read them ("invalid byte sequence in US-ASCII").

## Configuration

| Variable                | Default                       | Role                                                   |
|-------------------------|-------------------------------|--------------------------------------------------------|
| `WTS_BASE_BRANCH`       | detected                      | base of new branches; accepts a remote ref (`origin/main`) |
| `WTS_WORKTREES_BASE`    | `../<repo>-worktrees`         | where worktrees are created                            |
| `WTS_LAYOUTS_PATH`      | `~/.config/wts/layouts`       | user layouts, searched before the built-in ones        |
| `WTS_SUBDIR`            | (none)                        | subdirectory of the worktree where panes start         |
| `WTS_BRANCH_PREFIX`     | from the layout               | branch prefix override, even empty                     |
| `WTS_MODEL`             | `haiku`                       | model used for naming, `wts brief` and the retrospectives |
| `WTS_NO_LLM`            | (none)                        | `1`: never call the model                              |
| `WTS_NAME_TIMEOUT`      | `30`                          | naming timeout, seconds                                |
| `WTS_BRIEF_TIMEOUT`     | `45`                          | timeout of one summary, seconds                        |
| `WTS_BRIEF_JOBS`        | `4`                           | concurrent summaries                                   |
| `WTS_RETRO_TIMEOUT`     | `60`                          | timeout of one retrospective, seconds                  |
| `WTS_RETRO_JOBS`        | `3`                           | concurrent retrospectives (`wts retro --jobs`)         |
| `WTS_NO_ARCHIVE`        | (none)                        | `1`: `wts rm` and `wts gc` archive nothing for `wts log` |
| `WTS_ARCHIVE_TRANSCRIPT`| `1`                           | `0`: the archive points at the transcript without copying it |
| `WTS_NO_THINGS`         | (none)                        | `1`: never read Things (a machine without it, or to keep the macOS prompt away) |
| `WTS_THINGS_FROM_SCRIPT`| (none)                        | `1`: read Things without a terminal (a cron job); never set it for an agent |
| `WTS_THINGS_DB`         | found in Things' container    | path of the Things database to read instead            |
| `WTS_TASK_MAX_CHARS`    | `16000`                       | cap on a task's section of the context file            |
| `WTS_CONTEXT_QUIET`     | (none)                        | `1`: the SessionStart hook says only who the agent is and its task; the note line and the overlap warning are silent |
| `WTS_DOCS_PATH`         | `~/.config/wts/docs.json`     | the context document library                           |
| `WTS_DOC_TTL`           | `86400`                       | seconds before an attached URL document is fetched again |
| `WTS_DOC_TIMEOUT`       | `90`                          | fetch timeout, seconds (MCP handshakes are slow)       |
| `WTS_DOC_MODEL`         | `sonnet`                      | model used to fetch a document (fidelity over latency) |
| `WTS_DOC_TOOLS`         | (enumerated)                  | pinned allow patterns for the fetch, space-separated   |
| `WTS_DOC_TOOLS_TTL`     | `86400`                       | seconds the `claude mcp list` enumeration is cached    |
| `WTS_DOC_MAX_BYTES`     | `200000`                      | cap on a document, and on all of them together         |
| `WTS_STALE_AFTER`       | `10`                          | seconds before a frozen `working` agent shows `stuck?` |
| `WTS_NOTIFY`            | `1`                           | `0`: no bell nor banner when an agent needs you; `bell` or `banner` keeps one |
| `WTS_NOTIFIER`          | `terminal-notifier` on PATH   | a terminal-notifier binary for the banner (click switches to the session) |
| `WTS_NOTIFY_TERMINALS`  | iTerm2, Terminal, Ghostty, …  | bundle ids counted as "a terminal in front" (macOS), space-separated |
| `WTS_SWITCH_REFRESH`    | `2`                           | switcher refresh interval, `0` for a static list       |
| `WTS_SWITCH_SCROLLBACK` | `2000`                        | lines of tmux history reachable in the preview         |
| `WTS_SWITCH_TASKS`      | `10`                          | tasks listed in the switcher, `0` to hide them         |
| `WTS_LOCK_STALE_AFTER`  | `300`                         | seconds before `wts gc` calls an `index.lock` stale    |
| `WTS_STATE_DIR`         | `$XDG_STATE_HOME/wts`         | where the state database lives                         |
| `WTS_DB`                | `$WTS_STATE_DIR/wts.db`       | the state database itself                              |
| `CLAUDE_CONFIG_DIR`     | `~/.claude`                   | where Claude Code keeps sessions and transcripts       |

`XDG_STATE_HOME` and `XDG_CONFIG_HOME` are honored.

`WTS_MODEL` is passed to `claude --model` as is. The `haiku` alias resolves on the
Claude API; behind Amazon Bedrock or Google Vertex AI it need not — ids are prefixed
(`anthropic.claude-haiku-4-5`) or dated with an `@` there. Set `WTS_MODEL` to the id
your platform accepts: an id `claude` does not recognize is answered in prose, which
`wts` reports as `claude: [claude-code:unrecognized_model]` and falls back from.

### Base branch detection

Without `WTS_BASE_BRANCH`, `wts` uses, in order: `origin/HEAD`, a local `main`, a
local `master`, the current branch. This detection does not fetch —
[`prefix+: wts`](#creating-from-tmux) is what guarantees a fresh base. On an old
clone without `origin/HEAD`, fix it with `git remote set-head origin -a`.

Everything that *compares* against the base — the delta and `^ahead` in `wts ls`,
the switcher and `wts status --json`, and `wts gc` and `wts brief` — uses
`origin/<base>` when that ref exists, since that is what branches are cut from. Your
local copy of the base is usually behind, and against it a branch with no commits of
its own is credited with everything the base was missing.

### Monorepo: `WTS_SUBDIR`

When you always work in a subdirectory, set `WTS_SUBDIR` and every pane starts
there instead of the worktree root; commands anchored at the root keep using
`WTS_ROOT`. Per repository, with direnv:

```sh
# <repo>/.envrc   (ignore it globally if the repository is shared)
export WTS_SUBDIR=apps/api
```

Or once: `WTS_SUBDIR=apps/api wts my-feature`. If the directory does not exist in
the worktree, `wts` warns and starts at the root.

### Large repositories

Every `wts ls`, `prefix+a` and switcher refresh runs `git status` on each
registered worktree. On a 150k-file repository that is half a second per
worktree, and with several worktrees the tree walks no longer fit the OS file
cache. Two git settings make it a few hundredths of a second: fsmonitor (git's
built-in file watcher, git 2.37+ on macOS) and the untracked cache. `wts setup git`
prints them; they apply to the repository and all its worktrees:

```sh
git config core.fsmonitor true
git config core.untrackedCache true
```

`wts ls` says so once on stderr when a pass takes more than three seconds and
the repository has not enabled them. Measurements and the reasoning are in
`docs/big-repo-analysis.md`.

## Idempotence

- An existing worktree is reused.
- An existing session is detected with `tmux has-session -t =<name>` — an **exact**
  match: without `=`, tmux accepts a prefix and `fix-login` would match
  `fix-login-2` — and `wts` attaches to it (or switches client, inside tmux) without
  running tmuxinator again.
- `wts restore` skips sessions that are already running.
- The registry entry is rewritten on each launch; `created_at` and `prompt` are kept.

## Known limitations

- **Session names are global** to the tmux server: two `auth-form` worktrees in two
  repositories would share one session and one registry key, so `wts auth-form`
  is refused while another repository has that session. Prefix the name
  (`api-auth-form`).
- **macOS first.** Linux is untested.
- **Some Claude Code internals are undocumented**: the `tmux` field of
  `~/.claude/sessions/<pid>.json` (used to target the preview pane), the record types
  of transcript `.jsonl` files and the way their directory is named. When they
  change, the affected columns and summaries degrade to `-` or raw facts; nothing
  else breaks.
- The restore pre-fill (`print -z`) assumes zsh in the panes.
- `wts gc` acts on the repository of the current directory (`wts rm` finds the
  session's repository through the registry).
- **A document fetched through `WebFetch` is a model's rendering of the page, not
  the page.** That tool summarizes whatever it reads, and asking it not to does not
  change that. A document read through an MCP connector comes back verbatim; check
  with `wts doc show <slug>` when fidelity matters.
- **A document's content is written in clear text inside the worktree**
  (`.wts/context.md`). Keep secrets out of the library.
- A session named `doc` is shadowed by the subcommand, as `pr` and `rm` already are.

## Contributing

Issues and pull requests are welcome. Run `zsh test/smoke.zsh` before submitting:
it drives a throwaway repository on an isolated tmux server, without calling the
model.

## License

[MIT](LICENSE)
