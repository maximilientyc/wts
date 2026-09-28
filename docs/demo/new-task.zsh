#!/usr/bin/env zsh
# Records docs/new-task.gif: ctrl-t creating a task in the switcher, and `enter`
# on a task asking what to do with it. Unlike record.zsh, no agent and no model
# call: the feature is the popup itself, so a throwaway repository, two idle
# sessions and a stand-in `claude` are enough, and a take costs nothing.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/new-task.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# The tape runs this same script with --setup inside vhs's terminal, which
# builds the sandbox and attaches to it. Everything lives under $D, on a tmux
# server of its own; your server, state and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-newtask

# The sandbox server is only ever named by its socket, never through
# TMUX_TMPDIR alone: with $TMUX set (this runs from inside tmux), a bare
# `tmux kill-server` goes to the server $TMUX names — yours. A first version of
# this script did exactly that at the end of a take.
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1 WTS_WORKTREES_BASE=$D/wt
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # `claude agents` answers "no agent"; anything else waits.
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  export PATH="$D/bin:$ROOT/bin:$PATH"
  # A user layout named default shadows the built-in one, whose pane would start
  # the REAL Claude Code (a pane's login shell rebuilds PATH past the stand-in).
  print -r -- "# wts: branch_prefix=feature/
name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q --bare $D/origin.git
  git clone -q $D/origin.git $D/api 2>/dev/null
  cd $D/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init && git push -q origin main 2>/dev/null
  git remote set-head origin -a >/dev/null
  tmux -f /dev/null new-session -d -s base -c $D/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"
  WTS_NO_ATTACH=1 wts auth-form >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts export-users-csv >/dev/null 2>&1
  # The checkout's bindings, not your installed wts's: prefix+s must open the
  # switcher being recorded.
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux kill-session -t base
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator; do
  command -v "$c" >/dev/null || { print -u2 -r -- "new-task: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "new-task: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/new-task.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 new-task.raw.gif -o docs/new-task.gif
rm -f new-task.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/new-task.gif"
