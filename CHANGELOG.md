# Changelog

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
