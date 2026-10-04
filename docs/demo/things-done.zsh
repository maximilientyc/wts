#!/usr/bin/env zsh
# Records docs/things-done.gif: a task completed in Things leaving the switcher
# at the next `wts task ls`. From 1.6.0 to 1.8.3 it never did: the guard in
# wts-things wanted a terminal on stderr too, every caller hides it, and the
# read was refused in silence. No agent and no model call: a throwaway
# repository, one idle session, a stand-in `claude`, and a Things database
# built under a HOME of the sandbox's own — your Things container is never read.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/things-done.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# The tape runs this same script with --setup inside vhs's terminal, which
# builds the sandbox and attaches to it. Everything lives under $D, on a tmux
# server of its own; your server, state and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-thingsdone

# Named by its socket, never through TMUX_TMPDIR alone: with $TMUX set (this
# runs from inside tmux), a bare `tmux kill-server` goes to your server.
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_NO_THINGS WTS_THINGS_DB WTS_THINGS_BIN WTS_THINGS_FROM_SCRIPT
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_WORKTREES_BASE=$D/wt WTS_PR_REFRESH=0
  # WTS_PR_REFRESH=0: the switcher's PR poll would ask gh about a local origin,
  # with no login under this XDG_CONFIG_HOME, and preview its error.
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $D/home $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
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

  # Things, as wts-things reads it: the columns it names, dates as Unix epochs.
  # One task completed an hour ago, in Things only; one still open.
  local tdir="$D/home/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/ThingsData-DEMO/Things Database.thingsdatabase"
  mkdir -p "$tdir"
  integer now=$(date +%s)
  sqlite3 -init /dev/null "$tdir/main.sqlite" "
    CREATE TABLE TMTask (uuid TEXT PRIMARY KEY, title TEXT, notes TEXT, status INTEGER,
      stopDate REAL, trashed INTEGER, type INTEGER, area TEXT, creationDate REAL,
      userModificationDate REAL, startDate INTEGER);
    CREATE TABLE TMArea (uuid TEXT PRIMARY KEY, title TEXT);
    CREATE TABLE TMTag (uuid TEXT PRIMARY KEY, title TEXT);
    CREATE TABLE TMTaskTag (tasks TEXT, tags TEXT);
    INSERT INTO TMArea VALUES ('area1', 'Platform');
    INSERT INTO TMTask VALUES
      ('ThingsRotateKeys', 'Rotate API keys', '', 3,
       $(( now - 3600 )), 0, 0, 'area1', $(( now - 86400 * 3 )), $(( now - 3600 )), NULL),
      ('ThingsRoadmap', 'Q4 roadmap', '', 0,
       NULL, 0, 0, 'area1', $(( now - 86400 * 2 )), $(( now - 86400 )), NULL);" >/dev/null

  tmux -f /dev/null new-session -d -s base -c $D/api -x 148 -y 44
  # HOME only for the pane shells, where `wts task ls` is typed: wts-things
  # globs Things' container under it, and $D/home holds the database above.
  # Not for the whole sandbox: tmuxinator can be a version manager's shim
  # (asdf), which finds nothing under another HOME and exits 126.
  tmux set -g default-command "exec env HOME=$D/home zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"
  WTS_NO_ATTACH=1 wts auth-form >/dev/null 2>&1
  # wts's snapshots as they stood yesterday: both Things tasks open, as the last
  # read left them, and a local task beside them.
  wts task new "Migration docs" >/dev/null 2>&1
  sqlite3 -init /dev/null $XDG_STATE_HOME/wts/wts.db "
    INSERT INTO tasks (id, source, title, status, area, synced_at) VALUES
      ('ThingsRotateKeys', 'things', 'Rotate API keys', 'open', 'Platform',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 day')),
      ('ThingsRoadmap', 'things', 'Q4 roadmap', 'open', 'Platform',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 day'));" >/dev/null
  # The checkout's bindings, not your installed wts's: prefix+s must open the
  # switcher being recorded.
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux kill-session -t base
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "things-done: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "things-done: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/things-done.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 things-done.raw.gif -o docs/things-done.gif
rm -f things-done.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/things-done.gif"
