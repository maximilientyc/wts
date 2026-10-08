#!/usr/bin/env zsh
# Records docs/native-messaging.gif: two real agents reach each other with
# Claude Code's own messages (SendMessage), as the skill and the session
# context now tell them to. `api-docs` is idle; `rate-limit` is told, by a
# `wts send` from you, to ask it something. Its context names the agent to
# reach ("reach `api-docs` with SendMessage"); the message starts a turn in
# api-docs, whose answer comes back the same way; the hook records both as
# prompts of kind message, from their sender.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/native-messaging.zsh
#
# Real agents (Sonnet, a few turns on your account), a logged-in `claude`
# 2.1.224 or later, on a throwaway repository under $D and a tmux server of its
# own. Your Claude Code configuration is used as it is (login, folder trust),
# except for wts: the repository's project settings run THIS checkout's hooks
# on the sandbox's database, and the panes point WTS_DB at a file that does
# not exist, which keeps the hooks of your installed wts silent.
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and fixed: macOS caps the tmux socket path at 104 bytes, and Claude
# Code asks once per new folder whether to trust it.
D=/private/tmp/wts-nmdemo
# Inherited from the terminal this runs in, they would name YOUR server.
unset TMUX TMUX_PANE
export TMUX_TMPDIR=$D/tmux
SOCK="$TMUX_TMPDIR/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null && sleep 1
  return 0
}
die() { print -u2 -r -- "native-messaging: $*"; kill_sandbox; exit 1 }

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq claude; do
  command -v "$c" >/dev/null || die "$c not found"
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || die "vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"

kill_sandbox
rm -rf $D
rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/-private-tmp-wts-nmdemo-*(N)
mkdir -p $TMUX_TMPDIR $D/state

export XDG_STATE_HOME=$D/state WTS_LAYOUTS_PATH=$D/layouts WTS_DOCS_PATH=$D/docs.json
export WTS_NO_THINGS=1 WTS_NOTIFY=0 ANTHROPIC_MODEL="${WTS_DEMO_MODEL:-sonnet}"
export EDITOR=true PS1='%F{blue}%1~%f %F{magenta}❯%f '
export PATH="$ROOT/bin:$ROOT/libexec/wts:$PATH"
unset WTS_BRANCH_PREFIX WTS_BASE_BRANCH WTS_SUBDIR WTS_WORKTREES_BASE WTS_NO_LLM
mkdir -p $WTS_LAYOUTS_PATH
REAL_DB=$D/state/wts/wts.db

# The repository: a README to read, and the checkout's hooks as its project
# settings, each told where the sandbox's database is.
git init -q -b main $D/repo
cd $D/repo || die "no repo"
print -r -- "# api

A tiny HTTP API: GET /users, GET /users/:id, POST /login." > README.md
mkdir .claude
wts setup claude 2>/dev/null | grep -v '^//' \
  | jq --arg db "$REAL_DB" '{hooks: (.hooks | map_values(map(.hooks |= map(.command = "WTS_DB=\($db) " + .command))))}' \
  > .claude/settings.json || die "no hooks"
git add -A && git -c commit.gpgsign=false commit -qm init

# A server without your tmux.conf (prefix C-b), panes in a bare zsh that keeps
# this PATH, and WTS_DB for every pane but the demo's own shell. The demo's
# shell is named too: default-command is set after the server exists, and a
# login shell rebuilds PATH — the first take ran the installed wts there.
tmux -f /dev/null new-session -d -s demo -c $D/repo -x 148 -y 44 -e WTS_DB=$REAL_DB "exec zsh -f"
tmux set -g default-size 148x44
tmux set -g default-command "exec zsh -f"
tmux set -g status-right ""
tmux set -g status-style "bg=#313244,fg=#cdd6f4"
tmux set-environment -g WTS_DB $D/no-such.db

trust() {  # answers Claude Code's folder trust dialog in the sandbox's panes
  local p
  for p in $(tmux list-panes -a -F '#{pane_id}'); do
    tmux capture-pane -p -t $p | grep -q 'Yes, I trust this folder' && tmux send-keys -t $p Down Enter
  done
}
agent_is() {  # <session> <state>
  [[ "$(wts status --json --no-git 2>/dev/null | jq -r --arg n $1 '.[] | select(.name == $n) | .agent_state')" == $2 ]]
}
start() {  # <session> <prompt>: the built-in layout, without its editor pane
  WTS_NO_ATTACH=1 wts "$1" "$2" --json >/dev/null 2>&1 || die "wts $1 failed"
  tmux kill-pane -t "=${1}:code.0"
  integer w=0
  until agent_is $1 idle; do
    trust
    (( (w += 2) <= 180 )) || die "$1 never became idle"
    sleep 2
  done
}
print -r -- "native-messaging: starting api-docs, then rate-limit"
start api-docs "You document the public API of this repository: read README.md and wait. When another Claude session asks you something, answer it with SendMessage in one sentence."
# Second: its SessionStart context lists api-docs, whose agent now runs.
start rate-limit "Read README.md and wait for my instructions."

print -r -- "native-messaging: recording"
cd "$ROOT" || die "no checkout"
"$VHS" docs/demo/native-messaging.tape >/dev/null || die "vhs failed"
gifsicle -O3 --lossy=30 --colors 128 native-messaging.raw.gif -o docs/native-messaging.gif
rm -f native-messaging.raw.gif
if [[ -z "${WTS_DEMO_KEEP:-}" ]]; then
  kill_sandbox
  rm -rf $D
  rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/-private-tmp-wts-nmdemo-*(N)
fi
print -r -- "wrote docs/native-messaging.gif"
