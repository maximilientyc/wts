#!/usr/bin/env zsh
# Records docs/retro-model.gif: WTS_RETRO_MODEL picks the model of the
# retrospectives, and the dry run of `wts gc` names it in the cost it announces.
# No agent and no model call: the stand-in claude answers the retrospective
# with the --model it was given, so the archive shows which one was asked.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/retro-model.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-retmod

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_MODEL
  kill_sandbox
  rm -rf $D
  # WTS_RETRO_MODEL empty, not unset: every wts script is a zsh script and reads
  # ~/.zshenv again, which may export a default of its own.
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM= WTS_NO_THINGS=1 WTS_RETRO_MODEL= GIT_PAGER=cat PAGER=cat
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # The stand-in claude: a retrospective (-p) answered with the model it was
  # asked for, anything else idles like an agent.
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
if [ "$1" = -p ]; then
  cat >/dev/null
  printf "delivered: the login redirect fixed (written by %s)\nresisted: nothing notable\nresolved: -\nabandoned: -\n" "$3"
  exit 0
fi
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
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  WTS_NO_ATTACH=1 wts fix-login >/dev/null 2>&1
  w=$D/code/api-worktrees/fix-login
  print fixed > $w/login.txt
  git -C $w add . && git -C $w commit -qm "Fix the login redirect"
  git merge -q --ff-only "$(git -C $w branch --show-current)"
  git push -q origin main 2>/dev/null
  tmux kill-session -t base
  clear
  cd $D/code/api
  exec zsh -f
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "retro-model: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "retro-model: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/retro-model.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 retro-model.raw.gif -o docs/retro-model.gif
rm -f retro-model.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/retro-model.gif"
