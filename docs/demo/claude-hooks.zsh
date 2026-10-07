#!/usr/bin/env zsh
# Records docs/claude-hooks.gif: what the seventh hook and the payload fields
# change. An agent that quit reads stopped; claude run again in its pane (a
# SessionStart) reads idle at once and takes a prompt, where it used to need
# --force until its first one. A compaction leaves a working agent working.
# `wts tail` reads the transcript Claude Code named, wherever it is. An overlap
# found at a subagent's edit says so. The built-in layout names the conversation
# after the session. No agent and no model call: `as-claude` runs the hooks with
# the payloads Claude Code would send.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/claude-hooks.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own.

set -uo pipefail

ROOT="${0:A:h:h:h}"
D=/tmp/wts-hooksdemo

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
  mkdir -p $D/bin $D/elsewhere
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
  - main:" > $XDG_CONFIG_HOME/wts/layouts/bare.yml
  wts setup claude --install >/dev/null 2>&1
  git init -q $D/code/api
  cd $D/code/api || exit 1
  mkdir -p src && print "export {}" > src/limits.ts && print "# api" > README.md
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  # A layout of its own, so that `wts layouts` shows the built-in default one.
  WTS_NO_ATTACH=1 wts cors "CORS for the public API" bare >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts rate-limit "rate-limit per API key" bare >/dev/null 2>&1
  # Resolved (/private/tmp on macOS): Claude Code reports its cwd resolved.
  W=${D:A}/code/api-worktrees
  # as-claude <session> start <source> | prompt | end | edit <path> [subagent]
  # The hook as Claude Code runs it: from the agent's pane, its payload on stdin.
  print -r -- "#!/usr/bin/env zsh
s=\$1 verb=\$2; shift 2
sid=0123abcd-ef01-2345-6789-abcdef00000\${\${s:#cors}:+2}\${\${(M)s:#cors}:+1}
tr='$D/elsewhere/'\$sid.jsonl
pane=\$(tmux display-message -p -t \"=\$s:\" '#{pane_id}')
case \$verb in
  start) p=\$(jq -nc --arg s \$sid --arg t \$tr --arg k \$1 '{session_id: \$s, transcript_path: \$t, source: \$k}') ;;
  edit)  p=\$(jq -nc --arg s \$sid --arg f '$W/'\$s/\$1 --arg a \"\${2:+sub-1}\" \\
            '{session_id: \$s, tool_name: \"Edit\", tool_input: {file_path: \$f}} + (if \$a == \"\" then {} else {agent_id: \$a} end)')
         verb=touch ;;
  *)     p=\$(jq -nc --arg s \$sid --arg t \$tr '{session_id: \$s, transcript_path: \$t, reason: \"prompt_input_exit\"}') ;;
esac
out=\$(cd '$W/'\$s && print -r -- \$p | TMUX_PANE=\$pane wts-hook \$verb)
[[ -n \$out ]] && print -r -- \$out | jq -r '.hookSpecificOutput.additionalContext // .'
exit 0" > $D/bin/as-claude
  chmod +x $D/bin/as-claude
  as-claude cors prompt
  as-claude rate-limit prompt
  as-claude rate-limit edit src/limits.ts
  as-claude rate-limit end
  print -r -- '{"type":"assistant","timestamp":"2026-10-07T18:40:00Z","message":{"content":[{"type":"text","text":"Back: the limits are per API key now, 429 with Retry-After. Next: the PR."}]}}' \
    > $D/elsewhere/0123abcd-ef01-2345-6789-abcdef000002.jsonl
  sqlite3 -init /dev/null $XDG_STATE_HOME/wts/wts.db "
    UPDATE agent_events SET at = at - 900 WHERE event = 'prompt';
    UPDATE agent_events SET at = at - 360 WHERE event = 'end';
    UPDATE touches SET at = at - 700;"
  sleep 1
  tmux new-session -d -s demo -c $D/code/api -x 148 -y 44
  tmux kill-session -t base
  clear
  exec tmux attach -t demo
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "claude-hooks: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "claude-hooks: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/claude-hooks.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 claude-hooks.raw.gif -o docs/claude-hooks.gif
rm -f claude-hooks.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/claude-hooks.gif"
