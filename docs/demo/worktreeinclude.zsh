#!/usr/bin/env zsh
# Records docs/worktreeinclude.gif: a repository with an ignored .env, a nested
# local config and a .worktreeinclude; `wts <name>` copies what the file names
# into the new worktree and says how many. Like new-task.zsh, no agent and no
# model call: the feature is a copy at creation, a stand-in `claude` is enough.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/worktreeinclude.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-wtinclude

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_WORKTREES_BASE WTS_SUBDIR WTS_BASE_BRANCH
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1 WTS_NO_ATTACH=1
  # git speaks the host's language otherwise; messages only, glyphs stay UTF-8.
  export LC_MESSAGES=en_US.UTF-8 LANGUAGE=en
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  export PATH="$D/bin:$ROOT/bin:$PATH"
  # A user layout named default shadows the built-in one, whose pane would start
  # the REAL Claude Code (a pane's login shell rebuilds PATH past the stand-in).
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  print "# api" > README.md
  printf '%s\n' '.env' 'config/' > .gitignore
  git add . && git commit -qm init
  print 'API_TOKEN=dev-123' > .env
  print 'SIGNING_KEY=do-not-copy' > secret.env
  mkdir -p config && print 'port: 4000' > config/local.yml
  printf '%s\n' '*.env' '!secret.env' 'config/' > .worktreeinclude
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44 "zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"
  clear
  exec tmux attach -t base
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator; do
  command -v "$c" >/dev/null || { print -u2 -r -- "worktreeinclude: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "worktreeinclude: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/worktreeinclude.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 worktreeinclude.raw.gif -o docs/worktreeinclude.gif
rm -f worktreeinclude.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/worktreeinclude.gif"
