# wts — worktree sessions for parallel coding agents

`wts` creates a git worktree and a tmux session on it in one command, from a
layout you pick — by default an editor next to a Claude Code pane. It is made for
running several agents on the same repository at once without them stepping on
each other, and for finding your way back afterwards:

- **Survives reboots.** Every session is recorded as *(name, layout, context)* in a
  small registry, so `wts restore` rebuilds them all — worktrees survive a reboot,
  tmux does not.
- **Shows what each agent is doing.** `wts ls` and the fzf switcher (`prefix+s`)
  tell you which Claude Code agent is blocked, idle or working, with a stale guard
  that catches agents claiming to work on a frozen pane.
- **Cleans up after squash merges.** `wts gc` compares patch-ids against
  `origin/<base>`, so branches merged by squash or rebase are recognized, not left
  to pile up.
- **Tells you where you left off.** `wts brief` prints a two-line *done / next* per
  session, from git and the agent's transcript.
- **Starts from a sentence.** `wts "rate-limit the public API per key"` names the
  session for you and hands the sentence to Claude.

It is opinionated — zsh, tmux, tmuxinator, Claude Code — because it was built for
one person's workflow. It is shared in case that workflow is also yours.

![wts: a session started from a sentence, the switcher with agents blocked, working and idle, a blocked agent answered and an idle session stopped from the popup, then wts ls, wts brief and wts gc](docs/demo.gif)

## Requirements

- macOS (Linux is untested)
- zsh, git, tmux, [tmuxinator](https://github.com/tmuxinator/tmuxinator), fzf, jq, perl, curl
  (jq only ships with recent macOS; Homebrew installs it)
- Optional: [Claude Code](https://claude.com/claude-code), tested with 2.1.x — agent
  state columns, naming from a phrase, `wts brief`, resume on restore. Without it
  everything else works and the agent columns show `-`.
- Optional: [direnv](https://direnv.net), for a per-repository `WTS_SUBDIR`
- Optional: [gh](https://cli.github.com), for `ctrl-o` in the switcher and `wts pr`
  (open the session's pull request). Without it the key is not offered.

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
wts setup tmux >> ~/.tmux.conf && tmux source-file ~/.tmux.conf
```

| Key                          | Action                                                  |
|------------------------------|---------------------------------------------------------|
| `prefix+s`                   | session switcher — **replaces** tmux's default `choose-tree -s` |
| `prefix+a`                   | jump to the next agent that needs you                   |
| `prefix+:` then `wts …`      | create a session from a freshly fetched base            |
| `prefix+g`                   | the same prompt, pre-filled with `wts `                 |

The snippet uses absolute paths: tmux runs `command-alias` programs directly,
without a shell, so neither `~` nor `PATH` lookups are reliable there. Homebrew
paths point to the stable `opt/wts` location and survive `brew upgrade`.

## Quick start

```sh
cd ~/code/myapp
wts auth-form                          # ../myapp-worktrees/auth-form, branch auth-form
wts "rate-limit the public API per key"   # Claude proposes the name, starts on the task
wts ls                                 # agent state, branch, git delta, tmux state
wts stop auth-form                     # tmux session only; wts restore brings it back
wts rm auth-form -f                    # session + worktree + branch + registry entry
```

## Usage

```
wts <name> ["<phrase>"] [layout] [context...]
wts "<phrase>" [layout] [context...]
wts new [-p layout] <name|"phrase">...
wts ls
wts status [--json|--table|--fzf]
wts brief [name...]
wts restore [name...]
wts stop <name>
wts pr [name]
wts rm <name> [-f]
wts gc [--apply] [--no-fetch]
wts layouts
wts keys
wts setup tmux | git
wts help | wts version
```

```sh
wts auth-form feature                  # your "feature" layout: branch feature/auth-form
wts fix-ABC123 sentry ABC123           # "ABC123" reaches the layout as $WTS_CONTEXT
wts new cors rate-limit csv-export     # three worktrees and sessions at once
wts review/login-flow                  # an existing origin branch: checked out for review
wts rm auth-frm -f                     # typo-tolerant: resolves to auth-form
```

Slashes become `-` in the worktree folder and session name (`review/login-flow` →
`review-login-flow`); the git branch keeps its full name. `wts rm`, `wts stop` and `wts brief`
tolerate typos: substring match, then fzf fuzzy match, then edit distance; when
several sessions match, an fzf picker opens.

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
(about 5 s). The call is isolated: `--safe-mode`, hooks disabled, no MCP server, no
tool, no transcript, run outside any worktree. Past `WTS_NAME_TIMEOUT`, without
`claude`, or with `WTS_NO_LLM=1`, the name is derived locally from the phrase.

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
`idle`, `working`, then the rest. `wts status --json` exposes the same data
(`agent_state`, `stale`, git counters, tmux state) for scripts.

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
the same isolation as naming, `WTS_BRIEF_JOBS` calls at a time.

Each summary is **cached** in `~/.local/state/wts/brief/<name>`, keyed on HEAD,
uncommitted changes and the transcript's size and date: while nothing moved,
`wts brief` answers instantly. The transcript used is the live agent's, else the
most recent one of the worktree — never one older than the session, which would
belong to a previous session of the same name. Without `claude`, with
`WTS_NO_LLM=1`, or when the answer is malformed, the raw facts are shown. The model
is never called by `wts ls` or the switcher.

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
kills the selected tmux session (`wts stop`, after a y/N prompt: the worktree, the
branch and the registry entry stay, the popup stays open and the row reads
`stopped`), `ctrl-d` removes it entirely (`wts rm`), `ctrl-o` opens the branch's
pull request on GitHub (`wts pr`, through `gh pr view --web`: without a PR the popup
says so and stays open; without `gh` the key is neither bound nor listed),
`ctrl-f` / `ctrl-b` scroll the preview by half a page, `ctrl-r` reloads. The
current session is never killed from the popup, which it would close. tmux
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
of line. `*` after a name marks the session you came from. The preview takes the
right half.

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

`prefix+a` jumps straight to the next agent that needs you (`stuck?`, `blocked`,
`failed`, `idle`), without a popup; pressing it again cycles through them.

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

`ls`, `status`, `brief`, `restore`, `layouts`, `setup`, `help` and `version` are
passed through without fetching; `gc` and `rm` run from the main repository.

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

## Garbage collection

```sh
wts gc              # dry run: lists, deletes nothing
wts gc --apply      # does it
wts gc --no-fetch   # without contacting the remote (offline)
```

**The remote is the source of truth.** `wts gc` starts with
`git fetch --all --prune`, then compares against `origin/<base>` rather than a local
base that may lag behind. Six categories, limited to the current repository:

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

## Persistence and restore

A reboot kills the tmux server, **not the worktrees**. `wts` records every session
in `${XDG_STATE_HOME:-~/.local/state}/wts/sessions.json`:

```json
{
  "auth-form": {
    "profile": "feature",
    "repo_root": "/home/me/code/myapp",
    "worktree": "/home/me/code/myapp-worktrees/auth-form",
    "branch": "feature/auth-form",
    "subdir": "",
    "context": "",
    "prompt": "validate the email server-side before sending",
    "created_at": "2026-09-05T15:12:41Z"
  }
}
```

`wts restore [name...]` replays `tmuxinator start --no-attach` for every registered
session missing from tmux whose worktree still exists — all of them without
arguments. It never attaches: restoring eight sessions should not steal your
terminal. `wts ls` purges entries whose worktree is gone. This is a **declarative
replay**, not a snapshot like tmux-resurrect: a wts session is fully described by
its name, layout and context, so replaying the layout is more faithful.

`wts stop <name>` leaves the same state on purpose, without a reboot: the tmux
session is killed, everything else stays, and `wts restore <name>` replays it.

During `wts restore`, layouts see `WTS_RESTORE=1` and skip heavy commands —
otherwise eight sessions mean eight `claude` and eight dependency installs at once.
The Claude pane is not empty for all that: the command is **pre-filled** on the
pane's zsh command line (`print -z`), press Enter to run it. When a conversation
exists for the pane's directory, `WTS_RESUME=1` and `claude --continue` is proposed;
otherwise plain `claude`, since `--continue` would fail. The leading space keeps the
command out of your history (`histignorespace`).

```erb
<% claude_cmd =
    if restore
      ENV['WTS_RESUME'].to_s == '1' ? %q{" print -z 'claude --continue'"} : %q{" print -z claude"}
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
| `WTS_RESTORE` | `1` during `wts restore`                                         |
| `WTS_RESUME`  | `1` during `wts restore` when a Claude conversation exists       |

Use `WTS_WORKDIR` for `root:` and `WTS_ROOT` for commands that must run from the
worktree root. Panes do not inherit the environment of `wts` (the tmux server is
already running): read variables in ERB, not in pane commands. To start Claude with
the phrase, copy the `claude_cmd` block of `default.yml`, which escapes it for the
pane's shell. Keep layout files **ASCII**, comments included: without a UTF-8
locale (`LANG=C`), Ruby refuses to read them ("invalid byte sequence in US-ASCII").

## Configuration

| Variable                | Default                       | Role                                                   |
|-------------------------|-------------------------------|--------------------------------------------------------|
| `WTS_BASE_BRANCH`       | detected                      | base of new branches; accepts a remote ref (`origin/main`) |
| `WTS_WORKTREES_BASE`    | `../<repo>-worktrees`         | where worktrees are created                            |
| `WTS_LAYOUTS_PATH`      | `~/.config/wts/layouts`       | user layouts, searched before the built-in ones        |
| `WTS_SUBDIR`            | (none)                        | subdirectory of the worktree where panes start         |
| `WTS_BRANCH_PREFIX`     | from the layout               | branch prefix override, even empty                     |
| `WTS_MODEL`             | `haiku`                       | model used for naming and `wts brief`                  |
| `WTS_NO_LLM`            | (none)                        | `1`: never call the model                              |
| `WTS_NAME_TIMEOUT`      | `15`                          | naming timeout, seconds                                |
| `WTS_BRIEF_TIMEOUT`     | `45`                          | timeout of one summary, seconds                        |
| `WTS_BRIEF_JOBS`        | `4`                           | concurrent summaries                                   |
| `WTS_STALE_AFTER`       | `10`                          | seconds before a frozen `working` agent shows `stuck?` |
| `WTS_SWITCH_REFRESH`    | `2`                           | switcher refresh interval, `0` for a static list       |
| `WTS_SWITCH_SCROLLBACK` | `2000`                        | lines of tmux history reachable in the preview         |
| `WTS_LOCK_STALE_AFTER`  | `300`                         | seconds before `wts gc` calls an `index.lock` stale    |
| `CLAUDE_CONFIG_DIR`     | `~/.claude`                   | where Claude Code keeps sessions and transcripts       |

`XDG_STATE_HOME` and `XDG_CONFIG_HOME` are honored.

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
  repositories share one session and one registry key. Prefix the name
  (`api-auth-form`).
- **macOS first.** Linux is untested.
- **Some Claude Code internals are undocumented**: the `tmux` field of
  `~/.claude/sessions/<pid>.json` (used to target the preview pane), the record types
  of transcript `.jsonl` files and the way their directory is named. When they
  change, the affected columns and summaries degrade to `-` or raw facts; nothing
  else breaks.
- The restore pre-fill (`print -z`) assumes zsh in the panes.
- `wts rm` and `wts gc` act on the repository of the current directory.

## Contributing

Issues and pull requests are welcome. Run `zsh test/smoke.zsh` before submitting:
it drives a throwaway repository on an isolated tmux server, without calling the
model.

## License

[MIT](LICENSE)
