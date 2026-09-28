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
libexec/wts/wts-keys       the key table: switcher footer and `wts keys`
libexec/wts/wts-brief      done/next per session (Claude Haiku, cached)
libexec/wts/wts-doc        context document library: fetch (any MCP), cache, materialize
libexec/wts/wts-retro      capture at teardown: collect/store facts, write the retro (Haiku)
libexec/wts/wts-log        the work journal as one JSON document (archive + Things)
libexec/wts/wts-task       tasks: local ones and Things snapshots, the notes and
                           documents kept on them, link/unlink to sessions
libexec/wts/wts-things     Things 3 reader, read-only: tasks, their notes and links
libexec/wts/wts-db.zsh     the state database (SQLite): schema, import, helpers; sourced by all
                           also the one renderer for a task's context (task_context_md)
libexec/wts/wts-context    Claude Code SessionStart hook: tells an agent about the other sessions
libexec/wts/wts-hook       Claude Code UserPromptSubmit/Stop/Notification/SessionEnd hooks:
                           records agent_events, rings the bell, posts the banner
share/wts/layouts/         built-in layouts (default.yml)
examples/layouts/          richer layouts, not installed as built-ins
completions/_wts           zsh completion
test/smoke.zsh             end-to-end test in a sandbox
test/bench-big.zsh         speed on a generated large repository (make bench)
docs/big-repo-analysis.md  what that bench found, and the fixes it suggests
docs/demo/                record.zsh + demo.tape (README GIF, make demo)
                          + journal.tape (the wts log demo, WTS_DEMO_TAPE=)
                          + new-task.zsh/.tape (switcher tasks GIF, no agent, no model)
```

Homebrew, `make install` and a git checkout share this tree, so `bin/wts` works
straight from the checkout. Scripts locate each other from their own path
(`${0:A:h}`), never from `PATH` or `~/.config`.

## Conventions

- **English** everywhere: messages, comments, JSON values, prompts.
- Comments explain *why* (the failure that motivated the code), not what.
- `wts status --json` is a public contract: keys and `agent_state` values
  (`blocked working idle done failed stopped`, plus `stale`) do not change
  without a version bump and a CHANGELOG entry (1.5.0 added `agent_since` and
  `agent_source`; adding a key is fine that way, renaming one is not).
- A Claude Code hook never prints on stdout and always exits 0: Claude Code
  adds a `UserPromptSubmit` hook's stdout to the conversation, and reads a
  non-zero `Stop` hook as "block the turn, hand stderr to the model". `wts-hook`
  does `exec >/dev/null` right after reading its payload for that reason;
  `wts-context` is the one hook whose stdout is the point. So is `wts log`: its payload
  carries `version`, and the `outcome` vocabulary (`merged squashed
  remote-deleted removed abandoned in-progress unknown`) is closed — a seventh
  value breaks whatever agent is reading the corpus.
- Degrade, don't die: without `claude`, `jq`, `curl` or a tmux server, the
  affected columns show `-` and the rest works. Helpers use `set -uo pipefail`
  without `-e` for that reason; `bin/wts` uses `set -euo pipefail`.
- The model is only called on explicit commands (`wts "<phrase>"`, `wts brief`,
  `wts doc add|sync`, `wts retro`, and `wts gc --apply`), never from `ls`, the
  switcher or hooks. `WTS_NO_LLM=1` disables it. `gc` is the widest of these and
  the one to be careful with: it earns the call because a retrospective is only
  writable while the transcript exists, and it places it **after** the last
  destructive step, so interrupting it loses nothing but text. `wts-name`,
  `wts-brief` and `wts-retro` call the model with MCP and tools **off**;
  `wts-doc` is the one exception and says why in its header — fetching a page is
  precisely a job for the machine's own connectors, whose names differ from one
  machine to the next, so the allow list is enumerated, never hardcoded.
- **Another app's data is privileged on macOS 15+** (`~/Library/Containers`,
  `~/Library/Group Containers`): the first touch raises "iTerm would like to
  access data from other apps" — the *glob* raises it, before any open, and a
  denial is remembered. So the same rule as the model: only a command the user
  typed may read Things. Anything that merely describes what a key does asks
  `wts-things available`, which reads the cached verdict in `kv['things.db']`
  and nothing else. The switcher asked `wts-things db` on every popup open, to
  word one footer line: that dialog on every `prefix+s` is how it was found.
- Layout files stay ASCII (Ruby reads them under `LANG=C` otherwise fails). So do
  the switcher's display columns: `emit` pads them to an exact character count
  and the smoke test asserts it, but a glyph of East Asian **Ambiguous** width
  (U+25C6 `◆` among them) is two columns wide in some terminals — the row
  measures right and looks shifted. Sigils belong in unpadded output.
- The switcher's list line is **three TAB fields**: `<display>`, `<preview
  target>`, `<session name>`. A row that is not a session (the header, a task)
  leaves field 3 empty, which is what makes every `{3}` bind a no-op on it — so a
  new bind needs no knowledge of row kinds, but it must guard an empty name
  before passing it to a command. `wts rm ''` deletes by substring match and
  matches everything.
- State goes through `wts-db.zsh`, never a file of its own: `db_q` to write,
  `db_ro`/`db_rows` to read, every value through `sql_str`. The tables other
  than `notes` are written by wts only; `wts db` gives agents read access to all
  and write access to `notes` alone.

## zsh and tmux pitfalls already hit

- `$0` inside a function is the **function name** (`FUNCTION_ARGZERO`): resolve
  paths at top level (`WTS_SELF="${0:A}"`) and use the variable in functions.
- Quote tmux targets: `-t "=$name"`. Unquoted, `=name` is zsh's `=command`
  expansion and fails with "name not found". The `=` itself is required: without
  it tmux accepts a prefix and `fix-login` matches `fix-login-2`. With a format,
  add the colon: `display-message -p -t "=$name" '#{pane_width}'` prints an
  empty string and exits 0; `-t "=$name:"` prints the width. Same colon for
  `send-keys` and `capture-pane` on a server started with `-f /dev/null`:
  `-t "=$name"` fails with "can't find pane", `-t "=$name:"` works.
- `tmux new-session -e PATH=…` does not reach the pane: tmux rebuilds PATH
  for a new pane (other variables pass). To put a shim directory first, export
  it from a wrapper script that is the pane's command.
- A layout pane that runs `claude` runs the **real** Claude Code even inside a
  sandbox whose PATH starts with a stub: the pane's login shell rebuilds PATH.
  Sandbox layouts must name the stub by absolute path (`test/bench-big.zsh`).
- An interactive picker whose output is captured must not gate on `-t 1`. A
  helper that answers on stdout is read from a command substitution, which makes
  stdout a pipe in front of a real terminal — measured: `0-2` there, `012` only
  when nothing captures it (fzf's `execute` does hand its child all three).
  Test `-t 0`/`-t 2`; fzf draws on `/dev/tty`, not on the captured stdout, and
  works with its own stderr on `/dev/null`.
- `read -d` stops a process that fzf runs (reload, preview, transform): it puts
  the terminal in non-canonical mode through zsh's own tty — opened at startup
  even in a script — whatever it reads from, and fzf's children are in a
  background process group, so SIGTTOU stops them for good. Measured in a popup:
  `read -d x < <(print axb)` stops, `read -r` does not. Split `db_rows` output
  with `${(@ps:\x1e:)out}` on those paths instead (see `db_rows`).
- Field separator `\x1f`, not TAB: TAB is IFS whitespace, so `read` merges
  consecutive delimiters and shifts empty fields.
- Globs that may match nothing need `(N)`, or zsh prints "no matches found".
- `done` is a reserved word: not usable as a variable name.
- Outside a tmux client, `tmux display-message -p '#S'` returns the most recently
  used session, not "none": only trust it when `$TMUX` is set.
- Unix socket paths are capped at 104 bytes on macOS (fzf `--listen`, tmux).
- The schema block in `db_init` is one **double-quoted** zsh string (it
  interpolates the imports), so no comment in it may carry a backtick, a double
  quote or a `$`. A backtick runs as a command substitution — one of them really
  did create a worktree and a tmux session — and a double quote closes the
  string, after which the next newline ends the assignment and the rest of the
  schema is read as commands. Single quotes are safe.
- `local a="$1" b="$a"` does not work: `local` declares every name before it
  assigns, so `$a` is read while still unset and `set -u` fails. Split it.
- `${var:+--flag "$var"}` is **one** argument, not two: zsh does not word-split an
  unquoted parameter expansion (no `SH_WORD_SPLIT`). The callee receives
  `--flag value` as a single string, which matches no flag and is then used as a
  positional — silently, because the flag was optional. Use an array:
  `opt=(); [[ -n "$var" ]] && opt=(--flag "$var")`, then `"${opt[@]}"`.
- A function whose answer is read with `x=$(f)` runs in a **subshell**: globals it
  sets (`typeset -g`, an array of results) do not reach the caller. Either print
  everything on stdout, or set globals and return a status — not both.
- In `bin/wts` (`set -e`), a bare `[[ cond ]] && cmd` as a whole statement exits
  the script when the condition is false — the statement's own status is 1. Use
  an `if`. Helpers have no `-e`, which is why the same line is fine there. This
  broke `wts rm` once, silently, for every repository without `origin/HEAD`.
- `db_ro` returns a control character as the two characters `^_` (sqlite3 3.50+
  escapes them in its default output): `char(31)` joined in a SELECT and split
  with `IFS=$'\x1f'` reads as one field. Rows of several fields go through
  `db_rows`, which uses `-ascii`.
- `sqlite3`: always `-init /dev/null` (a user's `~/.sqliterc` with `.mode box`
  changes every output), and `.timeout` on every connection, or a concurrent
  writer fails with "database is locked". Rows with free text (prompts span
  lines) are read with `-ascii`: `\x1f` between fields, `\x1e` after each row,
  `read -d $'\x1e'`. `-newline ''` returns a value byte for byte.
- Quoting in zsh: `"${v//\'/\'\'}"` keeps the backslashes (inside double quotes
  `\'` is literal). Put the quote in a variable: `q="'"; "${v//$q/$q$q}"`.
- A SQL string passed as an argument to sqlite3 is not scanned for dot-commands
  past its start, but an argument that starts with `.` is one: `wts db sql` adds
  `-safe` so `.shell` and `readfile()` stay out of reach.
- A `TMUX_TMPDIR` that does not exist is **silently ignored** (tmux 3.4+): the
  command runs against `/tmp`, the real server. Create the folder before any
  `tmux kill-server` in a sandbox, or name the socket with `-S`. Same trap with
  `$TMUX` set: unset it first.
- tmuxinator waits for Enter after warning about a tmux release newer than its
  hard-coded list: always pass `--suppress-tmux-version-warning`, and `</dev/null`
  when its output is hidden.
- `git rev-parse --show-toplevel` answers with the **current** worktree. Run from
  inside a wts session (the layout's shell window, the switcher popup) that is
  the agent's worktree, and a path derived from it (`<worktree>-worktrees/`)
  points nowhere. Resolve the main worktree first (`main_worktree_of` in
  `bin/wts`, the first entry of `git worktree list`), and for a registered
  session read `worktree` and `repo_root` from the registry rather than deriving
  them. This is how `wts rm` once dropped a registry row while the worktree it
  described stayed on disk.
- Names typed by a human go through `registry_resolve_name`, which matches
  substrings **both ways**: `api-v2` resolves to `api`. Fine for `stop` and
  `brief`; a destructive verb must confirm a non-exact match, and refuse it when
  stdin is not a terminal.
- `$name:stop` is not "the value of name, then `:stop`": zsh reads `:s` as the
  substitution modifier (`${a[$name:stop]}` → "bad substitution"), and `:h`,
  `:t`, `:r`, `:e`, `:p` are modifiers too. Brace the parameter in a compound
  key: `${a[${name}:stop]}`.
- `read -q` reads the **terminal**, never stdin: a y/N cannot be fed from a pipe
  or a file, and without a tty it fails ("not interactive and can't open
  terminal") and counts as no. So the smoke test can only check that nothing
  happened without an answer, and that the prompt is in the source. Under fzf's
  `execute` the tty is there and the prompt works.
- `cmd | grep -q` under `pipefail` (the smoke test) fails when `cmd` prints
  more after the first match: grep quits, the rest hits a closed pipe, and the
  pipeline's status is that of `cmd`. Capture with `out=$(cmd)` and test `$out`.
- The status of a `while` loop is that of the last body command: a loop ending
  on `[[ cond ]] && print …` returns 1 whenever the condition was false on the
  last row, and a function ending on that loop returns it. `wts task show`
  exited 1 on every successful listing for that reason. End with `return 0`.

## Test

```sh
make lint    # zsh -n on every script
make test    # lint + test/smoke.zsh: throwaway repo, private tmux server
             # (TMUX_TMPDIR), private XDG dirs, stand-in `claude`, no model call
make bench   # test/bench-big.zsh: same sandbox, a generated 150k-file repository,
             # timings and process counts per command (TIER=small for a minute)
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
