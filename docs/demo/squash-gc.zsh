#!/usr/bin/env zsh
# Records docs/squash-gc.gif: `wts gc` picking up a branch squash-merged from
# several commits, which the patch-id test alone never recognized (#39 and #40
# stayed). Like read-data.zsh, no agent and no model call: the "GitHub" side is
# a second clone that squashes the branch onto origin/main, which is all a
# squash merge is to the repository.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/squash-gc.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-squashgc

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

# <name> <n>: n commits in the session's worktree.
commits() {
  local w=$D/code/api-worktrees/$1 i
  for i in {1..$2}; do
    print "$1, step $i" >> $w/$1.md
    git -C $w add . && git -C $w commit -qm "$1: step $i"
  done
}
# <name> <subject>: what GitHub's "Squash and merge" does, from another clone.
squash() {
  git -C $D/github pull -q --rebase origin main
  git -C $D/github fetch -q $D/code/api "$(git -C $D/code/api-worktrees/$1 branch --show-current)"
  git -C $D/github merge -q --squash FETCH_HEAD >/dev/null 2>&1
  git -C $D/github commit -qm "$2"
  git -C $D/github push -q origin main
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1 GIT_PAGER=cat PAGER=cat
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
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
  git init -q --bare $D/origin.git
  git clone -q $D/origin.git $D/code/api 2>/dev/null
  cd $D/code/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init && git push -q origin main 2>/dev/null
  git remote set-head origin -a >/dev/null
  git clone -q $D/origin.git $D/github 2>/dev/null
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  for s in fix-login rate-limit export-csv; do WTS_NO_ATTACH=1 wts $s >/dev/null 2>&1; done
  commits fix-login 3
  commits rate-limit 4
  commits export-csv 2
  # fix-login: 3 commits squashed into one. rate-limit: squashed too, then its
  # agent kept going — one commit the base does not have. export-csv: open.
  squash fix-login "Fix the login redirect (#39)"
  squash rate-limit "Rate-limit the public API (#40)"
  commits rate-limit 1
  print "## changelog" >> $D/github/README.md
  git -C $D/github commit -qam "Changelog" && git -C $D/github push -q origin main
  tmux kill-session -t base
  clear
  cd $D/code/api
  exec zsh -f
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "squash-gc: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "squash-gc: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/squash-gc.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 squash-gc.raw.gif -o docs/squash-gc.gif
rm -f squash-gc.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/squash-gc.gif"
