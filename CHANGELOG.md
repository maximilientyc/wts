# Changelog

## Unreleased

- The switcher's list (`prefix+s`) is laid out for the width it actually has. Columns were padded to 22/10/30/14 characters and never cut, so a session name over 22 characters or a `feature/<slug>` branch over 30 pushed its whole row to the right, and the fixed part alone was 80 columns wide when the list pane had 50 to 65: DELTA, SUBJECT and the ` *` mark of the current session were never on screen. The session and branch columns now take the width of their longest value, capped so every column stays visible, every cell too long for its column ends in `…`, and every row is exactly as wide as the list. `*` moved next to the session name. The header re-lays out with the rows (`--header-lines=1`), and the preview takes half the popup instead of 60%.

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
