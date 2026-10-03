#!/usr/bin/env zsh
# Records docs/pr-state.gif: the PR, CI and review state of each session —
# `wts pr --refresh`, the switcher's PR column with merged sessions last, the
# preview that spells a PR out, and ctrl-d on a squash-merged session. Like
# read-data.zsh, no agent and no model call; and no GitHub either: `gh` is a
# stand-in answering from fixtures, one per branch.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/pr-state.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-prstate

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_BASE_BRANCH
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1 WTS_DEMO_GH=$D/gh
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin $D/gh
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
exec sleep 3600' > $D/bin/claude
  # gh: `pr view <branch>` answers from $WTS_DEMO_GH/<branch>.json, a second
  # late as the real one is.
  print -r -- '#!/bin/sh
[ "$1 $2" = "pr view" ] || exit 1
sleep 1
f="$WTS_DEMO_GH/$3.json"
[ -f "$f" ] && { cat "$f"; exit 0; }
echo "no pull requests found for branch \"$3\"" >&2
exit 1' > $D/bin/gh
  chmod +x $D/bin/claude $D/bin/gh
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

  for s in auth-form rate-limit export-users-csv fix-typo docs-links; do
    WTS_NO_ATTACH=1 wts $s >/dev/null 2>&1
  done
  # Some work in each, so the delta column is not all zeros.
  for s in auth-form rate-limit export-users-csv; do
    print "$s" > $D/code/api-worktrees/$s/$s.txt
    git -C $D/code/api-worktrees/$s add . && git -C $D/code/api-worktrees/$s commit -qm "$s"
  done
  # fix-typo: its commit lands on origin/main squashed, as GitHub's squash
  # button does — another SHA, the same diff.
  wt=$D/code/api-worktrees/fix-typo
  print "# api, the HTTP API" > $wt/README.md
  git -C $wt commit -qam "Fix the README title"
  git clone -q $D/origin.git $D/squash 2>/dev/null
  print "# api, the HTTP API" > $D/squash/README.md
  git -C $D/squash commit -qam "Fix the README title (#40)"
  git -C $D/squash push -q origin HEAD:main 2>/dev/null
  git fetch -q origin

  pr() { # <branch> <number> <state> <review> <checks json>
    print -r -- "{\"number\":$2,\"state\":\"$3\",\"reviewDecision\":\"$4\",
      \"statusCheckRollup\":$5,\"mergedAt\":null,
      \"url\":\"https://github.com/acme/api/pull/$2\",\"headRefName\":\"$1\"}" > $D/gh/$1.json
  }
  ok='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
  pr auth-form 41 OPEN APPROVED "$ok"
  pr rate-limit 42 OPEN "" '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
                             {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]'
  pr export-users-csv 43 OPEN CHANGES_REQUESTED "$ok"
  pr fix-typo 40 OPEN "" "$ok"

  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  # The tape types the refresh itself; the switcher's timer must not beat it.
  tmux set-environment -g WTS_PR_REFRESH 0
  tmux kill-session -t base
  tmux send-keys -t "=auth-form:" "clear; git --no-pager log --oneline -3" Enter
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "pr-state: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "pr-state: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/pr-state.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 pr-state.raw.gif -o docs/pr-state.gif
rm -f pr-state.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/pr-state.gif"
