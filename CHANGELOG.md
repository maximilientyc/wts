# Changelog

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
