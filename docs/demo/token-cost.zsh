#!/usr/bin/env zsh
# Records docs/token-cost.gif: what each session and each task consumed. `wts
# ls --wide` before and after a `wts brief` (which sums the transcripts), the
# task's total over its attempts in `wts task show`, and the same numbers in
# `wts log`. Like read-data.zsh, no agent and no model call: the transcripts
# are written by hand in the sandbox's Claude directory, in the shape Claude
# Code writes them (usage repeated on every record of a message, a subagent's
# file under <session id>/subagents/), and WTS_NO_LLM=1 keeps brief local.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/token-cost.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-tokencost

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

# transcript <worktree> <file stem> <model> <messages> <output each> [sub]
# A transcript of <messages> turns: each is two records of the same message
# (thinking, then text), as Claude Code writes them, the cache growing turn
# by turn. With <sub>, a Haiku subagent's file next to it.
transcript() {
  local wt="$1" stem="$2" model="$3" n="$4" out="$5" sub="${6:-}" dir i
  dir="$CLAUDE_CONFIG_DIR/projects/${wt//[^a-zA-Z0-9]/-}"
  mkdir -p "$dir"
  for (( i = 1; i <= n; i++ )); do
    print -r -- "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_${stem}_$i\",\"model\":\"$model\",\"usage\":{\"input_tokens\":3,\"output_tokens\":$(( out / 2 )),\"cache_creation_input_tokens\":4000,\"cache_creation\":{\"ephemeral_1h_input_tokens\":4000},\"cache_read_input_tokens\":$(( 20000 + i * 4000 ))},\"content\":[{\"type\":\"thinking\"}]}}"
    print -r -- "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_${stem}_$i\",\"model\":\"$model\",\"usage\":{\"input_tokens\":3,\"output_tokens\":$out,\"cache_creation_input_tokens\":4000,\"cache_creation\":{\"ephemeral_1h_input_tokens\":4000},\"cache_read_input_tokens\":$(( 20000 + i * 4000 ))},\"content\":[{\"type\":\"text\",\"text\":\"turn $i\"}]}}"
  done > "$dir/$stem.jsonl"
  if [[ -n "$sub" ]]; then
    mkdir -p "$dir/$stem/subagents"
    print -r -- "{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"id\":\"msg_${stem}_sub\",\"model\":\"claude-haiku-4-5-20251001\",\"usage\":{\"input_tokens\":30000,\"output_tokens\":2500},\"content\":[{\"type\":\"text\",\"text\":\"found it\"}]}}" \
      > "$dir/$stem/subagents/agent-a1.jsonl"
  fi
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
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # ${D:A}: /tmp is /private/tmp on macOS, and Claude Code names the project
  # directory after the resolved path the worktree was registered under.
  wt=${D:A}/code/api-worktrees
  # A task tried once already: the first attempt is archived, and counted.
  task=$(wts task new "Rate-limit the public API" 2>/dev/null)
  WTS_NO_ATTACH=1 wts rate-limit --task "$task" >/dev/null 2>&1
  transcript $wt/rate-limit first claude-opus-5-5 60 1800
  wts rm rate-limit -f >/dev/null 2>&1
  db=$XDG_STATE_HOME/wts/wts.db
  sqlite3 -init /dev/null $db "UPDATE archive SET outcome = 'abandoned',
      retro_delivered = 'a fixed-window limiter, dropped for a token bucket'
    WHERE session = 'rate-limit'"
  # The second attempt and two other sessions, live.
  WTS_NO_ATTACH=1 wts rate-limit-v2 --task "$task" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts auth-form >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts export-users-csv >/dev/null 2>&1
  transcript $wt/rate-limit-v2 second claude-opus-5-5 45 2200 sub
  transcript $wt/auth-form third claude-opus-5-5 80 1500 sub
  transcript $wt/export-users-csv fourth claude-sonnet-5-5 25 900
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux kill-session -t base
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "token-cost: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "token-cost: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/token-cost.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 token-cost.raw.gif -o docs/token-cost.gif
rm -f token-cost.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/token-cost.gif"
