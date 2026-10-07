# Configuration

wts is configured with environment variables, set in your shell or, per
repository, with direnv. This guide lists them by theme, then covers the base
branch, monorepos and large repositories.

```
wts setup git
```

`XDG_STATE_HOME` and `XDG_CONFIG_HOME` are honored.

## Variables

### Sessions and branches

| Variable             | Default               | Role |
|----------------------|-----------------------|------|
| `WTS_BASE_BRANCH`    | detected              | base of new branches; accepts a remote ref (`origin/main`) |
| `WTS_WORKTREES_BASE` | `../<repo>-worktrees` | where worktrees are created |
| `WTS_LAYOUTS_PATH`   | `~/.config/wts/layouts` | user layouts, searched before the built-in ones |
| `WTS_SUBDIR`         | (none)                | subdirectory of the worktree where panes start |
| `WTS_BRANCH_PREFIX`  | from the layout       | branch prefix override, even empty |

### The model

| Variable            | Default  | Role |
|---------------------|----------|------|
| `WTS_MODEL`         | `haiku`  | model used for naming and `wts brief`, and the retrospectives' fallback |
| `WTS_RETRO_MODEL`   | `$WTS_MODEL` when set, else `haiku` | model used for the retrospectives |
| `WTS_NO_LLM`        | (none)   | `1`: never call the model |
| `WTS_NAME_TIMEOUT`  | `30`     | naming timeout, seconds |
| `WTS_BRIEF_TIMEOUT` | `45`     | timeout of one summary, seconds |
| `WTS_BRIEF_JOBS`    | `4`      | concurrent summaries |
| `WTS_RETRO_TIMEOUT` | `60`     | timeout of one retrospective, seconds |
| `WTS_RETRO_JOBS`    | `3`      | concurrent retrospectives (`wts retro --jobs`) |

`WTS_MODEL` is passed to `claude --model` as is. The `haiku` alias resolves on
the Claude API; behind Amazon Bedrock or Google Vertex AI it need not: ids are
prefixed (`anthropic.claude-haiku-4-5`) or dated with an `@` there. Set
`WTS_MODEL` to the id your platform accepts: an id `claude` does not recognize
is answered in prose, which `wts` reports as
`claude: [claude-code:unrecognized_model]` and falls back from.

`WTS_RETRO_MODEL` gives the retrospectives a stronger model without slowing
naming, which you wait on, or `wts brief`, which runs often: a retrospective is
written once per finished session and kept for months, and on the same facts
Haiku miscounted where Opus did not. Prefer an alias (`opus`, `sonnet`) to an
id there: Claude Code resolves an alias on each platform, so one value serves
a machine on the Claude API and one on Amazon Bedrock.

### Documents

| Variable            | Default                   | Role |
|---------------------|---------------------------|------|
| `WTS_DOCS_PATH`     | `~/.config/wts/docs.json` | the context document library |
| `WTS_DOC_TTL`       | `86400`                   | seconds before an attached URL document is fetched again |
| `WTS_DOC_TIMEOUT`   | `90`                      | fetch timeout, seconds (MCP handshakes are slow) |
| `WTS_DOC_MODEL`     | `$WTS_MODEL` when set, else `sonnet` | model used to fetch a document (fidelity over latency) |
| `WTS_DOC_TOOLS`     | (enumerated)              | pinned allow patterns for the fetch, space-separated |
| `WTS_DOC_TOOLS_TTL` | `86400`                   | seconds the `claude mcp list` enumeration is cached |
| `WTS_DOC_MAX_BYTES` | `200000`                  | cap on a document, and on all of them together |

### Tasks and Things

| Variable                 | Default                    | Role |
|--------------------------|----------------------------|------|
| `WTS_NO_THINGS`          | (none)                     | `1`: never read Things (a machine without it, or to keep the macOS prompt away) |
| `WTS_THINGS_FROM_SCRIPT` | (none)                     | `1`: read Things without a terminal (a cron job); never set it for an agent |
| `WTS_THINGS_DB`          | found in Things' container | path of the Things database to read instead |
| `WTS_TASK_MAX_CHARS`     | `16000`                    | cap on a task's section of the context file |
| `WTS_CONTEXT_QUIET`      | (none)                     | `1`: the SessionStart hook says only who the agent is and its task; the note line and the overlap warning are silent |

### Agent state, switcher and notifications

| Variable                | Default                     | Role |
|-------------------------|-----------------------------|------|
| `WTS_STALE_AFTER`       | `10`                        | seconds before a frozen `working` agent shows `stuck?` |
| `WTS_NOTIFY`            | `1`                         | `0`: no bell nor banner when an agent needs you; `bell` or `banner` keeps one |
| `WTS_NOTIFIER`          | `terminal-notifier` on PATH | a terminal-notifier binary for the banner (click switches to the session) |
| `WTS_NOTIFY_TERMINALS`  | iTerm2, Terminal, Ghostty, … | bundle ids counted as "a terminal in front" (macOS), space-separated |
| `WTS_SWITCH_REFRESH`    | `2`                         | switcher refresh interval, `0` for a static list |
| `WTS_PR_REFRESH`        | `300`                       | seconds between the switcher's background `wts pr --refresh`, `0` for never |
| `WTS_SWITCH_SCROLLBACK` | `2000`                      | lines of tmux history reachable in the preview |
| `WTS_SWITCH_TASKS`      | `10`                        | tasks listed in the switcher, `0` to hide them |

### Cleanup and the archive

| Variable                 | Default | Role |
|--------------------------|---------|------|
| `WTS_LOCK_STALE_AFTER`   | `300`   | seconds before `wts gc` calls an `index.lock` stale |
| `WTS_GC_GH_TIMEOUT`      | `20`    | timeout of `wts gc`'s one `gh pr list`, seconds |
| `WTS_NO_ARCHIVE`         | (none)  | `1`: `wts rm` and `wts gc` archive nothing for `wts log` |
| `WTS_ARCHIVE_TRANSCRIPT` | `1`     | `0`: the archive points at the transcript without copying it |

### State and paths

| Variable            | Default                 | Role |
|---------------------|-------------------------|------|
| `WTS_STATE_DIR`     | `$XDG_STATE_HOME/wts`   | where the state database lives |
| `WTS_DB`            | `$WTS_STATE_DIR/wts.db` | the state database itself |
| `CLAUDE_CONFIG_DIR` | `~/.claude`             | where Claude Code keeps sessions and transcripts |

## Base branch detection

Without `WTS_BASE_BRANCH`, `wts` uses, in order: `origin/HEAD`, a local `main`,
a local `master`, the current branch. This detection does not fetch:
[`prefix+: wts`](sessions.md#creating-from-tmux) is what guarantees a fresh
base. On an old clone without `origin/HEAD`, fix it with
`git remote set-head origin -a`.

Everything that *compares* against the base uses `origin/<base>` when that ref
exists, since that is what branches are cut from: the delta and `^ahead` in
`wts ls`, the switcher and `wts status --json`, and `wts gc` and `wts brief`.
Your local copy of the base is usually behind, and against it a branch with no
commits of its own is credited with everything the base was missing.

## Files copied into every worktree: `.worktreeinclude`

Untracked files a session needs (`.env`, local settings) are listed per
repository in `<repo>/.worktreeinclude`, in `.gitignore` syntax; `wts` copies
the matching ones from the main checkout into each new worktree. No variable:
the file is the setting, and without it nothing is copied. See [Untracked
files](sessions.md#untracked-files-worktreeinclude).

## Monorepo: `WTS_SUBDIR`

When you always work in a subdirectory, set `WTS_SUBDIR` and every pane starts
there instead of the worktree root; commands anchored at the root keep using
`WTS_ROOT`. Per repository, with direnv:

```sh
# <repo>/.envrc   (ignore it globally if the repository is shared)
export WTS_SUBDIR=apps/api
```

Or once: `WTS_SUBDIR=apps/api wts my-feature`. If the directory does not exist
in the worktree, `wts` warns and starts at the root.

## Large repositories

```sh
wts setup git                      # prints the two settings
git config core.fsmonitor true
git config core.untrackedCache true
```

Every `wts ls`, `prefix+a` and switcher refresh runs `git status` on each
registered worktree. On a 150k-file repository that is half a second per
worktree, and with several worktrees the tree walks no longer fit the OS file
cache.

Two git settings make it a few hundredths of a second: fsmonitor (git's
built-in file watcher, git 2.37+ on macOS) and the untracked cache. They apply
to the repository and all its worktrees.

`wts ls` says so once on stderr when a pass takes more than three seconds and
the repository has not enabled them. Measurements and the reasoning are in
[big-repo-analysis.md](big-repo-analysis.md).
