#!/usr/bin/env zsh
# Records docs/small-fixes.gif: the visible half of the Linux CI PR's fixes —
# a session name tmux would rewrite refused, a `claude agents` state outside
# the contract shown as none (and named by doctor), a session named `1`
# previewed as itself, and the task screen's branch hint saying what the
# default layout really does. Like pr-state.zsh, no agent and no model call.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/small-fixes.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-smallfix

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_BASE_BRANCH WTS_BRANCH_PREFIX
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1 WTS_DEMO_AGENTS=$D/agents.json
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # claude: `agents` answers from $WTS_DEMO_AGENTS, a state wts has never heard of.
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_DEMO_AGENTS" 2>/dev/null || echo "[]"; exit 0; }
[ "$1" = --version ] && { echo "0.0.0 (demo stand-in)"; exit 0; }
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  export PATH="$D/bin:$ROOT/bin:$PATH"
  # A user layout named default shadows the built-in one, whose pane would start
  # the REAL Claude Code. No branch prefix, like the built-in one.
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q --bare $D/origin.git
  git clone -q $D/origin.git $D/code/api 2>/dev/null
  cd $D/code/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init && git push -q origin main 2>/dev/null
  git remote set-head origin -a >/dev/null
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  for s in auth-form rate-limit 1; do
    WTS_NO_ATTACH=1 wts $s >/dev/null 2>&1
  done
  # ${D:A}: the registry holds the resolved path (/private/tmp on macOS), and
  # an agent's cwd is matched against it.
  jq -n --arg wt "${D:A}/code/api-worktrees" \
    '[{kind: "interactive", status: "busy", cwd: "\($wt)/auth-form", sessionId: "demo1"},
      {kind: "interactive", status: "pondering", cwd: "\($wt)/rate-limit", sessionId: "demo2"}]' \
    > $WTS_DEMO_AGENTS
  # Window 1 of auth-form is what a bare `-t 1` reached before tmux_target.
  tmux send-keys -t "=1:" "clear; print 'this is the session named 1'" Enter
  tmux new-window -d -t "=auth-form:1" "zsh -fc \"print 'window 1 of auth-form'; exec sleep 3600\""
  wts task new "Write the migration guide" >/dev/null

  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux set-environment -g WTS_PR_REFRESH 0
  tmux kill-session -t base
  tmux send-keys -t "=auth-form:" "clear" Enter
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "small-fixes: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "small-fixes: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/small-fixes.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 small-fixes.raw.gif -o docs/small-fixes.gif
rm -f small-fixes.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/small-fixes.gif"
