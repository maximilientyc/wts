#!/usr/bin/env zsh
# Records docs/long-prompt.gif: a 1.4 KB phrase through the layout as 1.6.0
# shipped it (typed into the pane, cut at the tty's 1024-byte line, claude never
# starts), then through the built-in layout, which reads it from .wts/prompt.
# Like new-task.zsh, no agent and no model call: the stand-in `claude` prints
# what it was given.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/long-prompt.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-longprompt

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
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
    WTS_NO_LLM=1 WTS_NO_THINGS=1
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # The stand-in says how much it received and how the phrase ends: the end is
  # what the tty used to drop.
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
printf "\033[1;32mclaude (stand-in)\033[0m received %s bytes\n\nends with: ...%s\n" \
  "$(printf %s "$*" | wc -c | tr -d " ")" "$(printf %s "$*" | tail -c 60)"
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  export PATH="$D/bin:$ROOT/bin:$PATH"
  # The pane's shell takes half a second to start, as an interactive zsh with
  # its rc files does: tmuxinator types the command meanwhile, into a tty still
  # in canonical mode. That window is the whole bug; `zsh -f` alone is too fast
  # to show it reliably.
  tmux_shell="sleep 0.5; exec zsh -f"
  # Both layouts name the stand-in by absolute path: a pane's login shell would
  # rebuild PATH past it and start the REAL Claude Code.
  to_stub() {
    sed -e "s#{claude #{$D/bin/claude #; s#\"claude #\"$D/bin/claude #; s#? 'claude' :#? '$D/bin/claude' :#" \
        -e 's#^name: #tmux_options: -f /dev/null\nname: #'
  }
  git -C "$ROOT" show v1.6.0:share/wts/layouts/default.yml | to_stub > $XDG_CONFIG_HOME/wts/layouts/typed.yml
  to_stub < "$ROOT/share/wts/layouts/default.yml" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init
  # The phrase: a task pasted from a ticket, 30 steps, quotes and all.
  perl -e 'print join(" ", map { "Step $_: migrate the \"$_\" handler, keep it'"'"'s tests green;" } 1..30), " Then open the PR."' > $D/spec.txt
  export EDITOR="fold -sw 64 $D/spec.txt"
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44 "zsh -f"
  tmux set -g default-command "$tmux_shell"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"
  clear
  exec tmux attach -t base
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator; do
  command -v "$c" >/dev/null || { print -u2 -r -- "long-prompt: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "long-prompt: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/long-prompt.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 long-prompt.raw.gif -o docs/long-prompt.gif
rm -f long-prompt.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/long-prompt.gif"
