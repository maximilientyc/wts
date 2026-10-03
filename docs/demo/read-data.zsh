#!/usr/bin/env zsh
# Records docs/read-data.gif: what wts now reads back of what it writes — the
# brief and notes above a session's pane, a task's previous attempts in its
# preview, the REPO column of `wts ls` and `wts gc --all`. Like new-task.zsh, no
# agent and no model call: the archive rows, the brief and the notes are written
# straight into the sandbox's database, which is exactly what wts reads.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/read-data.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-readdata

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
  # Two repositories: api has a remote, web is local only.
  git init -q --bare $D/origin.git
  git clone -q $D/origin.git $D/code/api 2>/dev/null
  cd $D/code/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init && git push -q origin main 2>/dev/null
  git remote set-head origin -a >/dev/null
  git init -q $D/code/web
  print "# web" > $D/code/web/README.md
  git -C $D/code/web add . && git -C $D/code/web commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # A task tried once already: that session is archived, with its retrospective.
  task=$(wts task new "Rate-limit the public API" 2>/dev/null)
  WTS_NO_ATTACH=1 wts rate-limit --task "$task" >/dev/null 2>&1
  wts rm rate-limit -f >/dev/null 2>&1
  db=$XDG_STATE_HOME/wts/wts.db
  sqlite3 -init /dev/null $db "UPDATE archive SET outcome = 'squashed',
      pr_url = 'https://github.com/acme/api/pull/42',
      retro_delivered = 'token bucket per key on /v1, with tests',
      retro_resisted = 'redis TTLs drifted under the test clock',
      retro_resolved = 'injected the clock into the limiter',
      retro_abandoned = 'per-route quotas, left for a decision'
    WHERE session = 'rate-limit'"
  wts task note "$task" "v2 must keep the same headers" >/dev/null 2>&1

  WTS_NO_ATTACH=1 wts auth-form >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts export-users-csv >/dev/null 2>&1
  ( cd $D/code/web && WTS_NO_ATTACH=1 wts landing-page >/dev/null 2>&1 )
  # What `wts brief` cached and what the agent left with `wts db set`.
  sqlite3 -init /dev/null $db "
    INSERT OR REPLACE INTO briefs VALUES ('auth-form', 'demo',
      'done: login form validates email and password, 6 tests' || char(10)
      || 'next: decide whether SSO users skip the form', strftime('%s','now') - 2400);
    INSERT OR REPLACE INTO notes VALUES
      ('auth-form', 'session-cookie', 'renamed sid to __Host-sid, SameSite=Lax',
       strftime('%Y-%m-%dT%H:%M:%SZ','now','-12 minutes')),
      ('auth-form', 'api-contract', 'POST /login now returns 422 on bad input',
       strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 minutes'))"
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux kill-session -t base
  # Something in the pane to preview under the memos.
  tmux send-keys -t "=auth-form:" "clear; git --no-pager log --oneline -3; ls" Enter
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "read-data: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "read-data: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/read-data.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 read-data.raw.gif -o docs/read-data.gif
rm -f read-data.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/read-data.gif"
