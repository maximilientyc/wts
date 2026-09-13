# Changelog

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
