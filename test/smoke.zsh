#!/usr/bin/env zsh
# Smoke test: drives wts end to end inside a sandbox. Throwaway git repo,
# private tmux server, private state/config/Claude dirs, a stand-in `claude`,
# no model call. Never touches your tmux server, registry or layouts.
#
# Usage: zsh test/smoke.zsh   (or: make test)

set -euo pipefail

ROOT="${0:A:h:h}"
WTS="$ROOT/bin/wts"

# /tmp rather than $TMPDIR: the tmux socket lives under TMUX_TMPDIR, and macOS
# caps unix socket paths at 104 bytes, which a long $TMPDIR can exceed.
SANDBOX=$(mktemp -d /tmp/wts-smoke.XXXXXX)
SANDBOX=${SANDBOX:A}

export TMUX_TMPDIR="$SANDBOX/tmux"
export XDG_STATE_HOME="$SANDBOX/state"
export XDG_CONFIG_HOME="$SANDBOX/config"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude"
export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export WTS_NO_LLM=1
unset TMUX WTS_LAYOUTS_PATH WTS_BRANCH_PREFIX WTS_BASE_BRANCH WTS_SUBDIR WTS_WORKTREES_BASE
mkdir -p "$TMUX_TMPDIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME/wts/layouts" "$CLAUDE_CONFIG_DIR" "$SANDBOX/bin"

cleanup() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

git config --global user.name smoke
git config --global user.email smoke@example.com
git config --global init.defaultBranch main

# Stand-in for Claude Code: reports the agents written to $WTS_SMOKE_AGENTS (none
# by default), and a pane that just waits.
export WTS_SMOKE_AGENTS="$SANDBOX/agents.json"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_SMOKE_AGENTS" 2>/dev/null || echo '[]'; exit 0; }
exec sleep 3600
EOF
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"

# A user layout: exercises the lookup order and the branch prefix header.
# `-f /dev/null` keeps your ~/.tmux.conf out of the sandbox server.
cat > "$XDG_CONFIG_HOME/wts/layouts/smoke.yml" <<'EOF'
# wts: branch_prefix=feature/
name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main:
EOF

integer passed=0
ok()   { print -r -- "ok   $1"; (( ++passed )) }
fail() { print -r -- "FAIL $1"; exit 1 }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
refute() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}
has_session() { tmux has-session -t "=$1" }
in_registry() { jq -e --arg n "$1" 'has($n)' "$XDG_STATE_HOME/wts/sessions.json" }

# ─── CLI surface ─────────────────────────────────────────────────────────────

check "version" eval '[[ "$("$WTS" --version)" == "wts "[0-9]* ]]'
check "help exits 0" "$WTS" --help
refute "unknown option fails" "$WTS" --bogus
check "setup tmux prints absolute helper paths" eval '"$WTS" setup tmux | grep -qF "$ROOT/libexec/wts/wts-fresh"'
check "layouts lists the user layout" eval '"$WTS" layouts | grep -q "^smoke	"'
check "layouts lists the built-in default" eval '"$WTS" layouts | grep -qF "default	$ROOT/share/wts/layouts/default.yml"'

# The built-in layout renders, fresh and restored, with a phrase to escape.
for restore in "" 1; do
  check "default layout renders (restore=${restore:-0})" env \
    WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE="$restore" \
    WTS_PROMPT="it's a test; ok" tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml"
done

# ─── Repo ────────────────────────────────────────────────────────────────────

REPO="$SANDBOX/code/demo"
WT="$SANDBOX/code/demo-worktrees"
mkdir -p "$REPO" "$SANDBOX/code/demo-notes"
print "keep me" > "$SANDBOX/code/demo-notes/todo.txt"
git -C "$REPO" init -q
print hello > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -qm init
cd "$REPO"

"$WTS" --help >/dev/null
refute "help creates no worktree" test -e "$WT/--help"

# ─── Create ──────────────────────────────────────────────────────────────────

WTS_NO_ATTACH=1 "$WTS" auth-form smoke >/dev/null
check "worktree created" test -d "$WT/auth-form"
check "branch prefix from the layout" git show-ref --verify --quiet refs/heads/feature/auth-form
check "tmux session started" has_session auth-form
check "session registered" in_registry auth-form

WTS_NO_ATTACH=1 "$WTS" "export users as csv" smoke >/dev/null
check "name derived locally from a phrase" has_session export-users-csv
check "phrase stored in the registry" \
  jq -e '.["export-users-csv"].prompt == "export users as csv"' "$XDG_STATE_HOME/wts/sessions.json"

refute "missing layout fails" env WTS_NO_ATTACH=1 "$WTS" other nope
refute "missing layout creates nothing" test -e "$WT/other"

# ─── Inspect ─────────────────────────────────────────────────────────────────

check "ls shows the session" eval '"$WTS" ls | grep -q "^auth-form "'
check "status --json" eval '"$WTS" status --json | jq -e "length == 2 and all(.[]; .exists and .tmux_alive)"'
check "status --fzf has 7 fields" eval '"$WTS" status --fzf | awk -F "\037" "NF != 7 { exit 1 }"'

# An interactive agent waiting for an answer needs a human: blocked, sorted first.
jq -n --arg cwd "$WT/export-users-csv" \
  '[{kind: "interactive", status: "waiting", cwd: $cwd, sessionId: "smoke"}]' > "$WTS_SMOKE_AGENTS"
check "waiting agent shown as blocked, first" \
  eval '"$WTS" status --json | jq -e ".[0].name == \"export-users-csv\" and .[0].agent_state == \"blocked\""'

# ─── Restore ─────────────────────────────────────────────────────────────────

tmux kill-session -t "=auth-form"
"$WTS" restore auth-form >/dev/null
check "restore restarts the session" has_session auth-form

# ─── gc ──────────────────────────────────────────────────────────────────────

print change > "$WT/auth-form/change.txt"
git -C "$WT/auth-form" add change.txt
git -C "$WT/auth-form" commit -qm change
git -C "$REPO" merge -q --ff-only feature/auth-form

"$WTS" gc --no-fetch --apply >/dev/null
refute "gc tears down the merged session" has_session auth-form
refute "gc removes the merged worktree" test -d "$WT/auth-form"
refute "gc deletes the merged branch" git show-ref --verify --quiet refs/heads/feature/auth-form
refute "gc drops the registry entry" in_registry auth-form
check "gc spares a branch without commits" has_session export-users-csv
check "gc spares its worktree" test -d "$WT/export-users-csv"
check "gc spares sibling folders" test -f "$SANDBOX/code/demo-notes/todo.txt"

# ─── rm ──────────────────────────────────────────────────────────────────────

"$WTS" rm export-users-csv -f >/dev/null
refute "rm kills the session" has_session export-users-csv
refute "rm removes the worktree" test -d "$WT/export-users-csv"
refute "rm deletes the branch" git show-ref --verify --quiet refs/heads/feature/export-users-csv
refute "rm drops the registry entry" in_registry export-users-csv

print -r -- "── $passed checks passed"
