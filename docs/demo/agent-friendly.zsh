#!/usr/bin/env zsh
# Records docs/agent-friendly.gif: wts from the agent's side — a session created
# detached with its JSON, an agent waited for, its last words read and a line
# sent to it, and what the hooks now tell an agent: the file another session
# edits too, the note a sibling left since its last turn, how its task was
# linked. No agent and no model call: the stand-in `claude` reports what the
# tape writes, and the hooks are run with the payloads Claude Code would send.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/agent-friendly.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
D=/tmp/wts-agentdemo

# TMUX_PANE too: inherited from the terminal this runs in, it would name a pane
# of YOUR server, and the hooks run below would record it as an agent's.
unset TMUX TMUX_PANE
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH
  kill_sandbox
  rm -rf $D
  mkdir -p $D/bin
  # tmuxinator keeps the real HOME: a version manager's Ruby is found through it.
  print -r -- "#!/bin/sh
HOME='$HOME' exec '$(command -v tmuxinator)' \"\$@\"" > $D/bin/tmuxinator
  chmod +x $D/bin/tmuxinator
  export HOME=$D/home TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_THINGS=1 WTS_NO_LLM=1 WTS_NOTIFY=0 WTS_SMOKE_AGENTS=$D/agents.json
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $HOME $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_SMOKE_AGENTS" 2>/dev/null || echo "[]"; exit 0; }
[ "$1" = --version ] && { echo "2.1.0 (Claude Code)"; exit 0; }
cat >/dev/null
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  print -r -- '[]' > $D/agents.json
  # The checkout's wts and its helpers (wts-context, wts-hook) first on PATH.
  export PATH="$D/bin:$ROOT/bin:$ROOT/libexec/wts:$PATH"
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  mkdir -p src && print "export {}" > src/limits.ts && print "# api" > README.md
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # Two agents at work, and a task one of them serves.
  WTS_NO_ATTACH=1 wts rate-limit "rate-limit the public API per key" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts auth-form "validate the signup form" >/dev/null 2>&1
  task=$(wts task new "Harden the public API" 2>/dev/null)
  wts task link "$task" auth-form >/dev/null 2>&1
  # Resolved (/private/tmp on macOS): Claude Code reports its cwd resolved, and
  # the collector matches an agent to a worktree by that path.
  W=${D:A}/code/api-worktrees
  # What their hooks recorded: the panes, a first turn each, the files edited.
  for s in rate-limit auth-form; do
    pane=$(tmux display-message -p -t "=$s:" '#{pane_id}')
    (cd $W/$s && print -r -- '{"session_id":"0123abcd-ef01-2345-6789-abcdef00000'${#s}'"}' \
       | TMUX_PANE=$pane wts-hook prompt)
  done
  (cd $W/rate-limit && print -r -- "{\"tool_input\":{\"file_path\":\"$W/rate-limit/src/limits.ts\"}}" | wts-hook touch)
  # rate-limit's conversation, for `wts tail`.
  proj="$CLAUDE_CONFIG_DIR/projects/${W//[^a-zA-Z0-9]/-}-rate-limit"
  mkdir -p "$proj"
  print -r -- '{"type":"assistant","timestamp":"2026-10-03T14:02:11Z","message":{"content":[{"type":"text","text":"Done: a token bucket per API key in src/limits.ts, 120 requests a minute, 429 with Retry-After past it. Tests pass. Shall I open the PR?"}]}}' \
    > "$proj/0123abcd-ef01-2345-6789-abcdef000010.jsonl"
  # It is working; the tape's hidden step runs go-idle, which turns it idle a
  # few seconds in (a tape cannot quote JSON).
  jq -n --arg cwd "$W/rate-limit" '[{kind: "interactive", status: "busy", cwd: $cwd, sessionId: "rl"}]' > $D/agents.json
  print -r -- "#!/bin/sh
sleep 4
jq -n --arg cwd '$W/rate-limit' '[{kind: \"interactive\", status: \"idle\", cwd: \$cwd, sessionId: \"rl\"}]' > '$D/agents.json'" > $D/bin/go-idle
  chmod +x $D/bin/go-idle
  sleep 1
  tmux new-session -d -s demo -c $D/code/api -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "agent-friendly: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "agent-friendly: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/agent-friendly.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 agent-friendly.raw.gif -o docs/agent-friendly.gif
rm -f agent-friendly.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/agent-friendly.gif"
