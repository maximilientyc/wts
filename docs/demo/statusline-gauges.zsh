#!/usr/bin/env zsh
# Records docs/statusline-gauges.gif: Claude Code's status line as a source.
# `wts setup claude --statusline` refuses a status line of your own and says
# how to chain both, then installs wts's; the payload Claude Code hands its
# status line becomes a line (session, model, context, who needs you, unseen
# notes) and a row of agent_gauges; `wts status --json`, `wts ls --wide` and
# the switcher read it. No agent and no model call: `payload` prints the JSON
# Claude Code would send, and `as-claude` runs the hooks with its payloads.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/statusline-gauges.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
D=/tmp/wts-sldemo

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
    CLAUDE_CONFIG_DIR=$D/home/.claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_THINGS=1 WTS_NO_LLM=1 WTS_NOTIFY=0 WTS_PR_REFRESH=0 WTS_SMOKE_AGENTS=$D/agents.json
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
  - main:" > $XDG_CONFIG_HOME/wts/layouts/bare.yml
  wts setup claude --install >/dev/null 2>&1
  # A status line of the user's own, which --statusline must not replace.
  jq '.statusLine = {type: "command", command: "~/bin/my-line.sh"}' $CLAUDE_CONFIG_DIR/settings.json \
    > $D/s.json && mv $D/s.json $CLAUDE_CONFIG_DIR/settings.json
  # Before the tmux server starts: its panes get the environment it starts with.
  export W=$D/code/api-worktrees
  git init -q $D/code/api
  cd $D/code/api || exit 1
  mkdir -p src && print "export {}" > src/limits.ts && print "# api" > README.md
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"
  WTS_NO_ATTACH=1 wts cors "CORS for the public API" bare >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts rate-limit "rate-limit per API key" bare >/dev/null 2>&1
  # payload <context %> [cost] [session name]: what Claude Code hands its
  # status line command on stdin (the fields wts reads).
  print -r -- "#!/usr/bin/env zsh
jq -nc --argjson c \${1:-0} --argjson usd \${2:-0} --arg n \"\${3:-}\" '{
  session_id: \"0123abcd-0000-0000-0000-0000000000\" + (\$c | tostring),
  session_name: \$n, model: {id: \"claude-opus-5-5\", display_name: \"Opus 5.5\"},
  cost: {total_cost_usd: \$usd}, context_window: {used_percentage: \$c},
  rate_limits: {five_hour: {used_percentage: 23}, seven_day: {used_percentage: 61}}}'" > $D/bin/payload
  chmod +x $D/bin/payload
  # as-claude <session> prompt | blocked: the hook as Claude Code runs it.
  print -r -- "#!/usr/bin/env zsh
s=\$1 verb=\$2
case \$verb in
  blocked) p='{\"session_id\":\"s-'\$s'\",\"notification_type\":\"permission_prompt\",\"message\":\"Bash: npm test\"}'
           verb=notification ;;
  *)       p='{\"session_id\":\"s-'\$s'\"}' ;;
esac
(cd \$W/\$s && print -r -- \$p | env -u TMUX_PANE wts-hook \$verb >/dev/null)
exit 0" > $D/bin/as-claude
  chmod +x $D/bin/as-claude
  as-claude cors prompt
  as-claude rate-limit prompt
  # rate-limit's own status line already reported once.
  (cd $W/rate-limit && payload 41 0.87 | wts-hook statusline >/dev/null)
  sqlite3 -init /dev/null $XDG_STATE_HOME/wts/wts.db "UPDATE agent_events SET at = at - 900"
  # The checkout's bindings: prefix+s must open the switcher being recorded.
  wts setup tmux > $D/dev.tmux && tmux source-file $D/dev.tmux
  sleep 1
  tmux new-session -d -s demo -c $W/cors -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "statusline-gauges: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "statusline-gauges: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/statusline-gauges.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 statusline-gauges.raw.gif -o docs/statusline-gauges.gif
rm -f statusline-gauges.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/statusline-gauges.gif"
