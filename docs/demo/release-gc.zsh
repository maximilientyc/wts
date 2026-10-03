#!/usr/bin/env zsh
# Records docs/release-gc.gif: `wts gc` picking up a branch squash-merged
# BEFORE a release. The release rewrote the CHANGELOG lines the squash landed,
# so merging the branch into the base conflicts and the content test says
# unmerged; gc now asks gh, after its fetch, which pull requests merged. Like
# squash-gc.zsh, no agent and no model call: the "GitHub" side is a second
# clone, and gh is a stand-in that answers `gh pr list` with that PR.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/release-gc.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-relgc

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

# <name> <entry>: two commits, the second adding its CHANGELOG entry.
work() {
  local w=$D/code/api-worktrees/$1
  print "$1" > $w/$1.txt
  git -C $w add . && git -C $w commit -qm "$1: code"
  sed -i.bak "s/^## Unreleased\$/## Unreleased\n\n- $2/" $w/CHANGELOG.md && rm -f $w/CHANGELOG.md.bak
  git -C $w commit -qam "$1: changelog"
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
  # The stand-in gh: `pr list` answers what GitHub would, anything else fails.
  print -r -- '#!/bin/sh
[ "$1 $2" = "pr list" ] && [ -f "'$D'/prs.json" ] && { cat "'$D'/prs.json"; exit 0; }
echo "no pull requests found" >&2; exit 1' > $D/bin/gh
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
  print -l "# Changelog" "" "## Unreleased" "" "## 1.8.1" "" "- earlier work" > CHANGELOG.md
  git add . && git commit -qm init && git push -q origin main 2>/dev/null
  git remote set-head origin -a >/dev/null
  git clone -q $D/origin.git $D/github 2>/dev/null
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  for s in fix-login export-csv; do WTS_NO_ATTACH=1 wts $s >/dev/null 2>&1; done
  work fix-login "Fix the login redirect"
  work export-csv "Export to CSV"
  # GitHub's "Squash and merge" of fix-login (#39), then the release: the
  # entry gets its PR number and "## Unreleased" becomes "## 1.9.0".
  b=$(git -C $D/code/api-worktrees/fix-login branch --show-current)
  git -C $D/github fetch -q $D/code/api "$b"
  git -C $D/github merge -q --squash FETCH_HEAD >/dev/null 2>&1
  git -C $D/github commit -qm "Fix the login redirect (#39)"
  sed -i.bak -e 's/^## Unreleased$/## 1.9.0/' -e 's/redirect$/redirect (#39)/' $D/github/CHANGELOG.md
  rm -f $D/github/CHANGELOG.md.bak
  git -C $D/github commit -qam "wts 1.9.0"
  git -C $D/github push -q origin main
  print -r -- '[{"number":39,"headRefName":"'$b'","headRefOid":"'$(git rev-parse "$b")'",
    "mergedAt":"2026-10-03T12:00:00Z","url":"https://github.com/acme/api/pull/39"}]' > $D/prs.json
  tmux kill-session -t base
  clear
  cd $D/code/api
  exec zsh -f
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "release-gc: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "release-gc: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/release-gc.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 release-gc.raw.gif -o docs/release-gc.gif
rm -f release-gc.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/release-gc.gif"
