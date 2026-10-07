#!/usr/bin/env zsh
# Records docs/structured-cost.gif: `wts brief` asks for a JSON answer against a
# schema, and what that call cost lands in the session's usage, under the
# transcript wts:brief. No agent and no model call: the stand-in claude is the
# smoke test's stub_claude, answering JSON when --output-format json is passed,
# with a cost of 0.0004 on claude-haiku-5-5 (a model the price table has no
# entry for, so the cost shown is the one claude reported).
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/structured-cost.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-structcost

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH WTS_MODEL WTS_RETRO_MODEL
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_THINGS=1
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  # The stand-in: `agents` for the collector, a JSON result for `claude -p
  # --output-format json`, its "label: value" lines as .structured_output.
  cat > $D/bin/claude <<'STUB'
#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
case " $* " in
  *" --output-format json "*) ;;
  *) exec sleep 3600 ;;
esac
cat >/dev/null
sleep 1
out='done: token bucket per API key on /v1, with 6 tests
next: decide the default quota for anonymous clients'
jq -cn --arg t "$out" '
  ($t | split("\n") | map(capture("^(?<key>[a-z]+): (?<value>.*)$")?) | from_entries) as $o
  | {type: "result", subtype: "success", is_error: false, result: $t,
     structured_output: $o, total_cost_usd: 0.0004,
     usage: {input_tokens: 10, output_tokens: 20, cache_creation_input_tokens: 100,
             cache_read_input_tokens: 0, cache_creation: {ephemeral_1h_input_tokens: 100},
             speed: "standard"},
     modelUsage: {"claude-haiku-5-5": {costUSD: 0.0004}}}'
STUB
  chmod +x $D/bin/claude
  export PATH="$D/bin:$ROOT/bin:$PATH"
  # A user layout named default shadows the built-in one, whose pane would start
  # the REAL Claude Code (a pane's login shell rebuilds PATH past the stand-in).
  print -r -- "name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:" > $XDG_CONFIG_HOME/wts/layouts/default.yml
  git init -q $D/code/api
  cd $D/code/api || exit 1
  print "# api" > README.md
  git add . && git commit -qm init
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  WTS_NO_ATTACH=1 WTS_NO_LLM=1 wts rate-limit "Rate-limit the public API per key" >/dev/null 2>&1
  wt=$(sqlite3 -init /dev/null $XDG_STATE_HOME/wts/wts.db "SELECT worktree FROM sessions WHERE name = 'rate-limit'")
  print "bucket" > $wt/limiter.go
  git -C $wt add . && git -C $wt commit -qm "token bucket per API key"
  clear
  exec zsh -f
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 jq; do
  command -v "$c" >/dev/null || { print -u2 -r -- "structured-cost: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "structured-cost: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/structured-cost.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 structured-cost.raw.gif -o docs/structured-cost.gif
rm -f structured-cost.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/structured-cost.gif"
