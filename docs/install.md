# Install

What wts needs, the two ways to install it, and the two optional integrations:
the tmux snippet (the switcher, `prefix+a`, the status line) and the Claude Code
hooks, permissions and skill. `wts doctor` checks all of it.

```
wts doctor [--json]
wts setup tmux [--install] | git | claude [--install]
```

## Requirements

- macOS (Linux is untested)
- zsh, git, tmux, [tmuxinator](https://github.com/tmuxinator/tmuxinator), fzf,
  jq, sqlite3 (3.38+, JSON built in), perl, curl. macOS ships sqlite3; jq only
  with recent releases, and Homebrew installs it.
- Optional: [Claude Code](https://claude.com/claude-code), tested with 2.1.x:
  agent state columns, naming from a phrase, `wts brief`, resume on restore.
  Without it everything else works and the agent columns show `-`.
- Optional: [direnv](https://direnv.net), for a per-repository `WTS_SUBDIR`
  (see [Monorepo](configuration.md#monorepo-wts_subdir)).
- Optional: [gh](https://cli.github.com), for `ctrl-o` in the switcher, its PR
  column and `wts pr` (open the session's pull request). Without it the key is
  not offered.

## Homebrew

Dependencies and zsh completion included. Recent Homebrew versions only load
formulae from taps you trust, so trust the tap first:

```sh
brew trust maximilientyc/tap
brew install maximilientyc/tap/wts
```

## From source

```sh
brew install tmux tmuxinator fzf jq
git clone https://github.com/maximilientyc/wts
cd wts
make install PREFIX=~/.local
```

Then make sure `~/.local/bin` is in your `PATH`, and add the completion
directory to `fpath` in `~/.zshrc`, before `compinit` runs (before oh-my-zsh, if
you use it):

```zsh
fpath=(~/.local/share/zsh/site-functions $fpath)
```

## The tmux integration

Optional, recommended.

```sh
wts setup tmux              # read it first
wts setup tmux --install && tmux source-file ~/.tmux.conf
```

It binds these keys:

| Key                     | Action                                                  |
|-------------------------|---------------------------------------------------------|
| `prefix+s`              | the [session switcher](switcher.md); **replaces** tmux's default `choose-tree -s` |
| `prefix+a`              | jump to the agent that has waited for you the longest   |
| `prefix+:` then `wts …` | create a session from a freshly fetched base ([Creating from tmux](sessions.md#creating-from-tmux)) |
| `prefix+g`              | the same prompt, pre-filled with `wts `                 |

It also appends a segment to `status-right`: `wts: 2 blocked · 1 idle`, and
nothing when nobody needs you. Keep it after the lines that set `status-right`
(a theme's), or they overwrite it.

### What `--install` does

- It writes the block between `# >>> wts` and `# <<< wts <<<` markers in
  `~/.tmux.conf`, and keeps a backup.
- On the next upgrade it replaces that block instead of adding a second one. A
  block appended without markers is replaced too.
- Move the `status-right` line out of the block, below your theme, and
  `--install` leaves it there and does not add a second one.

Run it again after `brew upgrade wts` when `wts doctor` says the snippet is
older than wts.

The snippet uses absolute paths: tmux runs `command-alias` programs directly,
without a shell, so neither `~` nor `PATH` lookups are reliable there. Homebrew
paths point to the stable `opt/wts` location and survive `brew upgrade`.

## The Claude Code integration

Optional, recommended: seven hooks, the permissions for wts's read-only verbs,
and a skill.

```sh
wts setup claude             # read it first
wts setup claude --install   # adds it to ~/.claude/settings.json (backup kept), writes the skill
```

The hooks go user-wide, in `~/.claude/settings.json`:

| Hook               | What it does |
|--------------------|--------------|
| `SessionStart`     | two hooks. `wts-context` tells every agent started in a wts session about its task and the other sessions, again after `/clear`, `/compact` and a resume ([Agents share state](agents.md#agents-share-state-wts-db)); `wts-hook start` records that a conversation starts, and how (`startup`, `resume`, `clear`, `compact`) |
| `UserPromptSubmit` | records that a turn starts; hands the agent the news since its last turn ([The news during a session](agents.md#the-news-during-a-session)) |
| `Stop`             | records that the turn is over; rings when an agent needs you ([When an agent needs you](watching.md#when-an-agent-needs-you)) |
| `Notification`     | records a permission or a question the agent waits on; rings |
| `SessionEnd`       | records that the agent quits |
| `PostToolUse`      | on `Edit`, `Write`, `MultiEdit`, `NotebookEdit`: records the file edited, and says when another session edits it too |

`wts-hook start` and the four after it are what dates the agent states in `wts
ls` and the switcher ([The agent's own events](watching.md#the-agents-own-events)).
Every one of them also records the agent's pane and the path of its transcript.
Anywhere outside a wts session every hook is silent. They read and write the
wts database only: no git, no model.

The permissions let an agent run these without a prompt, so no agent starts its
work blocked on one (`WTS_CLAUDE_ALLOW` in `libexec/wts/wts-db.zsh`):

```
wts db       wts task note   wts task show   wts task ls   wts status
wts ls       wts doc ls      wts doc show    wts log       wts help
wts doctor   wts brief --cached              wts wait      wts tail
```

Never `rm`, `gc`, `stop`, `send` or a creation.

The skill is `~/.claude/skills/wts/SKILL.md`. It lets a Claude started
*anywhere* find wts when you ask about parallel work: see [Driving wts from an
agent](agents.md#driving-wts-from-an-agent).

## Checking it: `wts doctor`

`wts doctor` checks:

- what is missing among the requirements;
- which switcher features an older fzf turns off: reply mode below 0.45, the
  fitted preview below 0.46, the key footer below 0.65;
- whether `claude agents --json` answers;
- whether the tmux snippet and the Claude hooks are installed and come from
  this wts, and whether the skill is.

It exits 1 when something required is missing. A creation also checks for tmux
and tmuxinator itself, before it makes a branch or a worktree.
