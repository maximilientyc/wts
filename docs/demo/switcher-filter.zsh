#!/usr/bin/env zsh
# Records docs/switcher-filter.gif: the switcher at fourteen sessions over two
# repositories — the per-state counts on its first line, the REPO column, and
# ctrl-g narrowing the list to the sessions that need you, then back. Like
# pr-state.zsh, no agent and no model call: the stand-in `claude agents`
# answers a state per worktree from a fixture.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/switcher-filter.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-filter

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
    WTS_NO_LLM=1 WTS_NO_THINGS=1 WTS_DEMO_AGENTS=$D/agents.json
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # `claude agents` answers the fixture: one agent per worktree, its state and
  # the name Claude gave its conversation.
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_DEMO_AGENTS" 2>/dev/null || echo "[]"; exit 0; }
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
  for r in api web; do
    mkdir -p $D/code/$r
    git -C $D/code/$r init -q
    print "# $r" > $D/code/$r/README.md
    git -C $D/code/$r add . && git -C $D/code/$r commit -qm init
  done
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 170 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # <repo> <session> <state> <conversation name> [<waiting for>]
  typeset -a agents
  agents=()
  session() {
    ( cd $D/code/$1 && WTS_NO_ATTACH=1 wts $2 >/dev/null 2>&1 )
    local wt=$D/code/$1-worktrees/$2
    print "$2" > $wt/$2.txt
    git -C $wt add . && git -C $wt commit -qm "$4"
    [[ "$3" == - ]] && return 0
    agents+=("$(jq -nc --arg cwd "${wt:A}" --arg st "$3" --arg n "$4" --arg w "${5:-}" \
      '{kind: "background", state: $st, cwd: $cwd, name: $n}
       + (if $w == "" then {} else {waitingFor: $w} end)')")
    # Something in the pane for the preview: what the agent last said. Typed
    # once every shell is up (below), or `clear` runs before the line is echoed.
    print -r -- "● $4"$'\n'"  ${5:-…}" > $wt/.wts-said
  }
  session api auth-form        blocked "Add the login form"        "Bash: npm run migrate"
  session api rate-limit       working "Rate-limit the public API"
  session web onboarding-tour  idle    "Onboarding tour, step 3"
  session api export-users-csv working "Export users as CSV"
  session web dark-mode        failed  "Dark mode toggle"          "tests failed: 3 snapshots"
  session api fix-pagination   working "Fix cursor pagination"
  session web image-lazyload   done    "Lazy-load the gallery"
  session api audit-log        blocked "Audit log for admin actions" "Edit: migrations/0042.sql"
  session web search-bar       working "Search bar with suggestions"
  session api webhooks-retry   working "Retry failed webhooks"
  session web footer-links     done    "Fix the footer links"
  session api cache-headers    idle    "Cache headers on /assets"
  session web i18n-dates       working "Localized dates"
  session api old-billing      -       "Billing v1 cleanup"
  print -r -- "[${(j:,:)agents}]" > $WTS_DEMO_AGENTS
  sleep 1
  for wt in $D/code/*-worktrees/*(/); do
    tmux send-keys -t "=${wt:t}:" "clear; cat .wts-said 2>/dev/null" Enter 2>/dev/null
  done
  # `clear` scrolls the typed line into the history, which the preview shows.
  sleep 1
  for wt in $D/code/*-worktrees/*(/); do
    tmux clear-history -t "=${wt:t}:" 2>/dev/null
  done
  # Stopped: its tmux session gone, the worktree kept (wts stop).
  wts stop old-billing >/dev/null 2>&1 || tmux kill-session -t "=old-billing" 2>/dev/null
  # Two tasks, to show the view hides them too.
  wts task new "Write the migration guide" >/dev/null 2>&1
  wts task new "Rotate the staging keys" >/dev/null 2>&1

  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  # No PR to show here, and the real gh, unauthenticated in the sandbox, would
  # put its login hint in every preview.
  tmux set-environment -g WTS_PR_REFRESH 0
  tmux kill-session -t base
  clear
  exec tmux attach -t auth-form
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "switcher-filter: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "switcher-filter: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/switcher-filter.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 switcher-filter.raw.gif -o docs/switcher-filter.gif
rm -f switcher-filter.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/switcher-filter.gif"
