#!/usr/bin/env zsh
# Records docs/exact-delivery.gif: what one agent shares reaches its sibling
# exactly once — a note rewritten in the same second arrives with its second
# value, a note written mid-turn arrives at the next edit, the first editor of
# a file hears that the other session edited it too, and a session removed
# with `wts rm -f` is announced with its outcome and the notes it left. No
# agent and no model call: the stand-in `claude` sleeps, and the hooks are run
# with the payloads Claude Code would send, through three short helpers:
#   note <session> <key> <value>   wts db set, from that session's worktree
#   turn <session>                 the UserPromptSubmit hook: what it adds
#   edit <session> <path>          the PostToolUse hook on an Edit: its
#                                  additionalContext
# Both hooks print nothing when there is nothing new; the helpers say
# "(nothing new)" so the silence shows.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/exact-delivery.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
D=/tmp/wts-exactdemo

# TMUX_PANE too: inherited from the terminal this runs in, it would name a pane
# of YOUR server, and the hooks run below would record it as an agent's.
unset TMUX TMUX_PANE
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH
  kill_sandbox
  rm -rf $D
  mkdir -p $D/bin
  # tmuxinator keeps the real HOME: a version manager's Ruby is found through it.
  print -r -- "#!/bin/sh
HOME='$HOME' exec '$(command -v tmuxinator)' \"\$@\"" > $D/bin/tmuxinator
  chmod +x $D/bin/tmuxinator
  export HOME=$D/home TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_THINGS=1 WTS_NO_LLM=1 WTS_NOTIFY=0 WTS_SMOKE_AGENTS=$D/agents.json
  # git speaks the recorder's language otherwise (`wts rm` shows its line).
  export LANGUAGE=en LC_MESSAGES=C
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $HOME $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_SMOKE_AGENTS" 2>/dev/null || echo "[]"; exit 0; }
[ "$1" = --version ] && { echo "2.1.0 (Claude Code)"; exit 0; }
cat >/dev/null
exec sleep 3600' > $D/bin/claude
  chmod +x $D/bin/claude
  print -r -- '[]' > $D/agents.json
  # Resolved (/private/tmp on macOS): what Claude Code reports as its cwd.
  W=${D:A}/code/api-worktrees
  print -r -- "#!/bin/zsh -f
cd '$W/'\"\$1\" && wts db set \"\$2\" \"\$3\" 2>/dev/null" > $D/bin/note
  print -r -- "#!/bin/zsh -f
out=\$(cd '$W/'\"\$1\" && print -r -- '{\"session_id\":\"s\"}' | wts-hook prompt)
print -r -- \"\${out:-(nothing new)}\"" > $D/bin/turn
  print -r -- "#!/bin/zsh -f
out=\$(cd '$W/'\"\$1\" && print -r -- \"{\\\"tool_name\\\":\\\"Edit\\\",\\\"tool_input\\\":{\\\"file_path\\\":\\\"$W/\$1/\$2\\\"}}\" \\
  | wts-hook touch | jq -r .hookSpecificOutput.additionalContext)
print -r -- \"\${out:-(nothing new)}\"" > $D/bin/edit
  chmod +x $D/bin/note $D/bin/turn $D/bin/edit
  # The checkout's wts and its helpers (wts-hook) first on PATH.
  export PATH="$D/bin:$ROOT/bin:$ROOT/libexec/wts:$PATH"
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  mkdir -p src && print "export {}" > src/limits.ts && print "export {}" > src/form.ts
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # Two sessions of one repository. rate-limit commits work of its own, so
  # its removal reads `abandoned`: the notes of an abandoned session mean the
  # opposite of a squashed one's.
  WTS_NO_ATTACH=1 wts auth-form "validate the signup form" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts rate-limit "rate-limit per API key" >/dev/null 2>&1
  (cd $W/rate-limit && print "export const LIMIT = 100" > src/limits.ts \
     && git commit -qam "limit per key")
  # The first turns, so the scenes start from "nothing new".
  turn auth-form >/dev/null; turn rate-limit >/dev/null
  sleep 1
  tmux new-session -d -s demo -c $D/code/api -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "exact-delivery: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "exact-delivery: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/exact-delivery.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 exact-delivery.raw.gif -o docs/exact-delivery.gif
rm -f exact-delivery.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/exact-delivery.gif"
