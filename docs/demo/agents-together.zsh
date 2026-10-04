#!/usr/bin/env zsh
# Records docs/agents-together.gif: what one agent can do to another, once wts
# looks first — `wts ls --wide` with since when and the question, a prompt
# refused to an agent that is blocked and its answer sent with --answer, a wait
# that ends on an agent that quit, a send refused to the shell its pane has
# become, a wait on a session no agent ever ran in, and a note written as
# another session refused without a terminal. No agent and no model call: the
# stand-in `claude` reports what the setup writes, and the hooks are run with
# the payloads Claude Code would send.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/agents-together.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
D=/tmp/wts-togetherdemo

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
  # The checkout's wts and its helpers (wts-hook) first on PATH.
  export PATH="$D/bin:$ROOT/bin:$ROOT/libexec/wts:$PATH"
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  mkdir -p src && print "export {}" > src/limits.ts && print "# api" > README.md
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # Four sessions: one agent asking a question, one at work, one that quit,
  # and one no agent ever ran in.
  WTS_NO_ATTACH=1 wts cors "CORS for the public API" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts auth-form "validate the signup form" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts rate-limit "rate-limit per API key" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts csv-export "export users as csv" >/dev/null 2>&1
  # Resolved (/private/tmp on macOS): Claude Code reports its cwd resolved, and
  # the collector matches an agent to a worktree by that path.
  W=${D:A}/code/api-worktrees
  ev() {  # <session> <verb> <json> — the hook, from the agent's own pane
    local pane
    pane=$(tmux display-message -p -t "=$1:" '#{pane_id}')
    (cd $W/$1 && print -r -- "$3" | TMUX_PANE=$pane wts-hook "$2")
  }
  ev cors prompt '{"session_id":"0123abcd-ef01-2345-6789-abcdef000001"}'
  ev cors notification '{"session_id":"0123abcd-ef01-2345-6789-abcdef000001","notification_type":"permission_prompt","message":"Bash: npm run db:migrate"}'
  ev auth-form prompt '{"session_id":"0123abcd-ef01-2345-6789-abcdef000002"}'
  ev rate-limit prompt '{"session_id":"0123abcd-ef01-2345-6789-abcdef000003"}'
  ev rate-limit end '{"session_id":"0123abcd-ef01-2345-6789-abcdef000003","reason":"prompt_input_exit"}'
  # The ages a few minutes of work leave behind (the hooks stamp "now").
  sqlite3 -init /dev/null $XDG_STATE_HOME/wts/wts.db "
    UPDATE agent_events SET at = at - 540 WHERE event = 'prompt' AND session IN ('cors', 'auth-form');
    UPDATE agent_events SET at = at - 240 WHERE event = 'notification';
    UPDATE agent_events SET at = at - 900 WHERE event = 'prompt' AND session = 'rate-limit';
    UPDATE agent_events SET at = at - 360 WHERE event = 'end';"
  # What `claude agents` says: cors waits for an answer, auth-form is busy,
  # and it has no record of the other two.
  jq -n --arg w "$W" '[
    {kind: "interactive", status: "waiting", waitingFor: "Bash: npm run db:migrate", cwd: ($w + "/cors"), sessionId: "c"},
    {kind: "interactive", status: "busy", cwd: ($w + "/auth-form"), sessionId: "a"}]' > $D/agents.json
  sleep 1
  tmux new-session -d -s demo -c $D/code/api -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "agents-together: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "agents-together: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/agents-together.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 agents-together.raw.gif -o docs/agents-together.gif
rm -f agents-together.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/agents-together.gif"
