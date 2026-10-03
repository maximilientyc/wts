#!/usr/bin/env zsh
# Records docs/command-surface.gif: the command surface of roadmap item 2 — a
# typo refused, `--help` per command, `wts doctor` before and after the two
# installs, Ctrl-C while a phrase is being named, and gc's dry run scoped to
# what wts made and saying what --apply will cost. Like read-data.zsh, no agent
# and no model call: the stand-in `claude` answers `agents` and `--version`, and
# otherwise never answers at all, which is exactly what Ctrl-C is for.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/command-surface.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, HOME included (so `setup tmux --install` and
# `doctor` read and write the sandbox's tmux.conf), on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-cmdsurf

unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_NO_LLM
  kill_sandbox
  rm -rf $D
  # No WTS_NO_LLM: gc's dry run names the model calls only when it would make
  # them. The stand-in claude below is first on PATH, so none can be real.
  # tmuxinator keeps the real HOME: a version manager's Ruby (asdf) is found
  # through it, and without it the shim exits 126 and no session starts.
  mkdir -p $D/bin
  print -r -- "#!/bin/sh
HOME='$HOME' exec '$(command -v tmuxinator)' \"\$@\"" > $D/bin/tmuxinator
  chmod +x $D/bin/tmuxinator
  export HOME=$D/home TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_THINGS=1
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $HOME $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
[ "$1" = --version ] && { echo "2.1.0 (Claude Code)"; exit 0; }
cat >/dev/null
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

  # A session whose work landed (fast-forward), and a branch made by hand that
  # landed too: gc takes the first and, by default, leaves the second alone.
  WTS_NO_ATTACH=1 wts auth-form >/dev/null 2>&1
  print "validate" > $D/code/api-worktrees/auth-form/form.txt
  git -C $D/code/api-worktrees/auth-form add . 
  git -C $D/code/api-worktrees/auth-form commit -qm "validate the form"
  git merge -q --ff-only auth-form
  git switch -q -c develop && print dev > dev.txt && git add . && git commit -qm dev
  git switch -q main && git merge -q --ff-only develop
  git push -q origin main 2>/dev/null
  WTS_NO_ATTACH=1 wts export-users-csv >/dev/null 2>&1

  # The popup keys from the checkout, not from an installed wts — and on purpose
  # not through `--install`: the tape shows doctor seeing the snippet missing.
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  tmux new-session -d -s demo -c $D/code/api -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3; do
  command -v "$c" >/dev/null || { print -u2 -r -- "command-surface: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "command-surface: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/command-surface.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 command-surface.raw.gif -o docs/command-surface.gif
rm -f command-surface.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/command-surface.gif"
