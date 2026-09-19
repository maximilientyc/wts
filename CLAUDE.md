# wts — notes for contributors (and coding agents)

zsh tool: git worktree + tmuxinator session per task, with Claude Code agent state.
User documentation is in `README.md`; this file is about working on the code.

## Layout

```
bin/wts                    entry point: dispatch, registry, layouts, normal flow
libexec/wts/wts-status     the single collector (registry + git + tmux + claude) → --json/--table/--fzf
libexec/wts/wts-switch     fzf popup (prefix+s) and --next (prefix+a)
libexec/wts/wts-gc         squash-aware cleanup, dry run by default
libexec/wts/wts-fresh      tmux `command-alias` entry: fetch origin/<default>, then wts
libexec/wts/wts-name       slug from a phrase (Claude Haiku, local fallback)
libexec/wts/wts-brief      done/next per session (Claude Haiku, cached)
share/wts/layouts/         built-in layouts (default.yml)
examples/layouts/          richer layouts, not installed as built-ins
completions/_wts           zsh completion
test/smoke.zsh             end-to-end test in a sandbox
docs/demo/                record.zsh + demo.tape: the README GIF (make demo)
```

Homebrew, `make install` and a git checkout share this tree, so `bin/wts` works
straight from the checkout. Scripts locate each other from their own path
(`${0:A:h}`), never from `PATH` or `~/.config`.

## Conventions

- **English** everywhere: messages, comments, JSON values, prompts.
- Comments explain *why* (the failure that motivated the code), not what.
- `wts status --json` is a public contract: keys and `agent_state` values
  (`blocked working idle done failed stopped`, plus `stale`) do not change
  without a version bump and a CHANGELOG entry.
- Degrade, don't die: without `claude`, `jq`, `curl` or a tmux server, the
  affected columns show `-` and the rest works. Helpers use `set -uo pipefail`
  without `-e` for that reason; `bin/wts` uses `set -euo pipefail`.
- The model is only called on explicit commands (`wts "<phrase>"`, `wts brief`),
  never from `ls`, the switcher or hooks. `WTS_NO_LLM=1` disables it.
- Layout files stay ASCII (Ruby reads them under `LANG=C` otherwise fails).

## zsh and tmux pitfalls already hit

- `$0` inside a function is the **function name** (`FUNCTION_ARGZERO`): resolve
  paths at top level (`WTS_SELF="${0:A}"`) and use the variable in functions.
- Quote tmux targets: `-t "=$name"`. Unquoted, `=name` is zsh's `=command`
  expansion and fails with "name not found". The `=` itself is required: without
  it tmux accepts a prefix and `fix-login` matches `fix-login-2`. With a format,
  add the colon: `display-message -p -t "=$name" '#{pane_width}'` prints an
  empty string and exits 0; `-t "=$name:"` prints the width.
- Field separator `\x1f`, not TAB: TAB is IFS whitespace, so `read` merges
  consecutive delimiters and shifts empty fields.
- Globs that may match nothing need `(N)`, or zsh prints "no matches found".
- `done` is a reserved word: not usable as a variable name.
- Outside a tmux client, `tmux display-message -p '#S'` returns the most recently
  used session, not "none": only trust it when `$TMUX` is set.
- Unix socket paths are capped at 104 bytes on macOS (fzf `--listen`, tmux).
- A `TMUX_TMPDIR` that does not exist is **silently ignored** (tmux 3.4+): the
  command runs against `/tmp`, the real server. Create the folder before any
  `tmux kill-server` in a sandbox, or name the socket with `-S`. Same trap with
  `$TMUX` set: unset it first.
- tmuxinator waits for Enter after warning about a tmux release newer than its
  hard-coded list: always pass `--suppress-tmux-version-warning`, and `</dev/null`
  when its output is hidden.

## Test

```sh
make lint    # zsh -n on every script
make test    # lint + test/smoke.zsh: throwaway repo, private tmux server
             # (TMUX_TMPDIR), private XDG dirs, stand-in `claude`, no model call
```

Run it before every push; CI runs the same on `macos-latest`. To try the tmux
integration from a checkout without touching an installed wts:

```sh
bin/wts setup tmux > /tmp/wts-dev.tmux && tmux source-file /tmp/wts-dev.tmux
tmux source-file ~/.tmux.conf   # back to the installed version
```

When a change shows in the README demo (switcher, `wts ls`, `brief`, `gc`
output), re-record `docs/demo.gif` with `make demo`: real agents on a throwaway
clone, a few minutes and a few agent turns. Requirements are in the header of
`docs/demo/record.zsh`.

## Release

The formula's test checks `wts --version`, and Homebrew only upgrades when the
version changes, so every release bumps it.

1. `WTS_VERSION` in `bin/wts`, a section in `CHANGELOG.md`; commit, push, wait for green CI.
2. `git tag -a vX.Y.Z -m "wts X.Y.Z" && git push origin vX.Y.Z`, then
   `gh release create vX.Y.Z --title "wts X.Y.Z" --notes …`.
3. `curl -sL https://github.com/maximilientyc/wts/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`.
4. In `maximilientyc/homebrew-tap`: update `url` and `sha256` in `Formula/wts.rb`,
   `brew audit --strict --online maximilientyc/tap/wts`, commit, push.
5. `brew update && brew upgrade wts`, then `brew test wts`.

To try `main` through Homebrew before tagging: `brew reinstall --HEAD maximilientyc/tap/wts`.
