#!/usr/bin/env zsh
# Smoke test: drives wts end to end inside a sandbox. Throwaway git repo,
# private tmux server, private state/config/Claude dirs, a stand-in `claude`,
# no model call. Never touches your tmux server, registry or layouts.
#
# Usage: zsh test/smoke.zsh   (or: make test)

set -euo pipefail

ROOT="${0:A:h:h}"
WTS="$ROOT/bin/wts"
SWITCH="$ROOT/libexec/wts/wts-switch"

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
# A line sent to a shell pane takes a moment to run and print: poll up to 3 s.
pane_shows() { # <session> <line>
  local i
  for i in {1..30}; do
    tmux capture-pane -p -t "=$1:" 2>/dev/null | grep -qx -- "$2" && return 0
    sleep 0.1
  done
  return 1
}
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

# The skeleton fzf opens on must be interchangeable with the collected list:
# 3 TAB fields, and the same sessions, or the swap would drop or shift rows.
check "switcher list has 3 fields" \
  eval '"$SWITCH" --list | awk -F "\t" "NF != 3 { exit 1 }"'
check "skeleton has 3 fields" \
  eval '"$SWITCH" --list-fast | awk -F "\t" "NF != 3 { exit 1 }"'
check "skeleton lists the same sessions" \
  eval 'diff <("$SWITCH" --list-fast | cut -f3 | sort) <("$SWITCH" --list | cut -f3 | sort)'
# Both go through emit, with widths measured on the same registry: if they ever
# disagree, every column redraws shifted at the swap. The header is the first
# line of each list, so equal headers means equal widths.
check "skeleton aligns with the collected list" \
  eval 'diff <("$SWITCH" --list-fast | head -1) <("$SWITCH" --list | head -1)'

# Every display field of stdin is exactly $1 characters wide. zsh's ${#} counts
# characters, unlike awk's length on macOS, so `…` costs one like any letter.
same_width() {
  local line
  while IFS=$'\t' read -r line _; do (( ${#line} == $1 )) || return 1; done
}
check "rows are padded to the list width" \
  eval 'WTS_SWITCH_COLS=60 "$SWITCH" --list | same_width 60 \
        && WTS_SWITCH_COLS=60 "$SWITCH" --list-fast | same_width 60'

# A cell longer than its column is cut with an ellipsis instead of pushing the
# rest of the row right. An unregistered tmux session is the cheapest long name.
LONG=a-session-name-long-enough-to-overflow-its-column
tmux new-session -d -s "$LONG" -x 80 -y 24
check "long cells are cut with an ellipsis" \
  eval 'WTS_SWITCH_COLS=60 "$SWITCH" --list | grep -q "^a-session-name[a-z-]*…"'
check "the cut row is as wide as the others" \
  eval 'WTS_SWITCH_COLS=60 "$SWITCH" --list | same_width 60'
tmux kill-session -t "=$LONG"

# fzf exits 2 on an unknown --bind action, and in a popup that means the frame
# closes without a word. --filter validates binds headlessly, so the actions the
# swap depends on are checked against the fzf actually installed.
check "the switcher swaps the skeleton on load, not on start" \
  grep -qF 'load:unbind(load)+reload-sync' "$SWITCH"
check "fzf accepts that bind" \
  eval 'printf "x\n" | fzf --bind="load:unbind(load)+reload-sync(true)" --filter=x'
check "fzf accepts the ctrl-x bind" \
  eval 'printf "x\n" | fzf --bind="ctrl-x:execute(true)+reload(true)" --filter=x'

# The preview is a raw capture at the pane's width: the window is fitted to it on
# focus, up to the half of the popup the list is laid out against, or a narrow
# agent pane leaves half of the window blank while the list is squeezed. --fit prints the action, fzf runs it.
check "fzf accepts the fit bind" \
  eval 'printf "x\n" | fzf --bind="focus:transform(true)" --filter=x'
# `=auth-form:` with the colon: `display-message -p -t "=auth-form"` prints an
# empty string and exits 0, so the check would fail on a format that never ran.
pane_width=$(tmux display-message -p -t "=auth-form:" '#{pane_width}')
check "--fit sizes the preview to the pane" \
  eval '[[ "$(FZF_COLUMNS=$((pane_width * 4)) "$SWITCH" --fit auth-form)" == "change-preview-window(right,$pane_width,border-left)" ]]'
check "--fit caps the preview at half the popup" \
  eval '[[ "$(FZF_COLUMNS=$pane_width "$SWITCH" --fit auth-form)" == "change-preview-window(right,$((pane_width / 2)),border-left)" ]]'
check "--fit stays quiet for an unknown target" \
  eval '[[ -z "$(FZF_COLUMNS=200 "$SWITCH" --fit no-such-session)" ]]'

# ─── Reply mode ──────────────────────────────────────────────────────────────
# The verbs are what fzf's `transform` runs on tab / enter / esc: each prints
# an action chain, and `send` types into a real pane of the private server.
# auth-form's pane is a plain shell here, so a sent command line runs.
check "fzf accepts the reply binds" \
  eval 'printf "x\n" | fzf --bind="tab:transform(true)" --bind="enter:transform(true)" \
          --bind="esc:transform(true)" --filter=x'
export WTS_SWITCH_REPLY="$SANDBOX/reply"
check "enter switches outside reply mode" \
  eval '[[ $("$SWITCH" --reply send x auth-form auth-form) == accept ]]'
check "esc closes the popup outside reply mode" \
  eval '[[ $("$SWITCH" --reply esc) == abort ]]'
# The chains the verbs print are what fzf executes: an action it does not know
# is dropped without a word, so each one is parsed by the installed fzf.
fzf_parses() { printf 'x\n' | fzf --bind="start:$1" --filter=x }
chain=$("$SWITCH" --reply toggle auth-form auth-form)
check "tab enters reply mode" \
  eval 'print -r -- "$chain" | grep -q "^disable-search+.*change-prompt|reply to auth-form> |$"'
check "fzf parses the enter chain" fzf_parses "$chain"
check "reply mode is pinned on disk" \
  eval '[[ $(head -1 "$WTS_SWITCH_REPLY") == auth-form ]]'
check "enter sends the line to the pane" \
  eval '[[ $("$SWITCH" --reply send "echo wts-reply-ok" auth-form auth-form) == "clear-query+refresh-preview" ]]'
check "the line reached the pane" pane_shows auth-form wts-reply-ok
check "an empty reply sends a bare Enter" \
  eval '[[ $("$SWITCH" --reply send "" auth-form auth-form) == "clear-query+refresh-preview" ]]'
# The pinned session wins over a cursor that drifted to another row.
"$SWITCH" --reply send "echo wts-reply-pinned" export-users-csv export-users-csv >/dev/null
check "a drifted cursor does not retarget the reply" pane_shows auth-form wts-reply-pinned
chain=$("$SWITCH" --reply esc)
check "esc leaves reply mode" \
  eval 'print -r -- "$chain" | grep -q "^enable-search+.*rebind(ctrl-d,ctrl-x)" && [[ ! -e "$WTS_SWITCH_REPLY" ]]'
check "fzf parses the leave chain" fzf_parses "$chain"
check "tab toggles back out too" \
  eval '"$SWITCH" --reply toggle auth-form auth-form >/dev/null && "$SWITCH" --reply toggle auth-form auth-form | grep -q "^enable-search" && [[ ! -e "$WTS_SWITCH_REPLY" ]]'
unset WTS_SWITCH_REPLY

# ─── No collector may take a worktree's index.lock ───────────────────────────
# `git status` creates <gitdir>/index.lock before it scans and only releases it
# after writing the refreshed index back. The collector statuses every registered
# worktree, on every `wts ls` and every switcher refresh (2 s by default), so it
# raced the agent's own `git add` in that worktree — and a pass killed mid-scan
# left a zero-byte lock that broke every write there until someone deleted it by
# hand, inside .git.
#
# A shim, not an assertion on the filesystem: git removes the lock when it
# finishes, so by the time the test could look, a lock correctly taken and no
# lock at all are indistinguishable. What has to be pinned is that these calls
# are never *allowed* to write.
export WTS_SMOKE_LOCKY="$SANDBOX/locky.log"
export WTS_SMOKE_REAL_GIT=$(command -v git)
mkdir -p "$SANDBOX/shim"
cat > "$SANDBOX/shim/git" <<'EOF'
#!/bin/sh
# --no-optional-locks and GIT_OPTIONAL_LOCKS come before the subcommand, so
# scanning in order and stopping there sees everything that matters.
for a in "$@"; do
  case "$a" in
    --no-optional-locks) nolocks=1 ;;
    status|diff)         sub="$a"; break ;;
  esac
done
if [ -n "$sub" ] && [ -z "$nolocks" ] && [ "$GIT_OPTIONAL_LOCKS" != 0 ]; then
  echo "$*" >> "$WTS_SMOKE_LOCKY"
fi
exec "$WTS_SMOKE_REAL_GIT" "$@"
EOF
chmod +x "$SANDBOX/shim/git"

: > "$WTS_SMOKE_LOCKY"
for probe in 'ls' 'status --json' 'brief' 'gc --no-fetch'; do
  PATH="$SANDBOX/shim:$PATH" "$WTS" ${=probe} >/dev/null 2>&1 || true
done
PATH="$SANDBOX/shim:$PATH" "$SWITCH" --list >/dev/null 2>&1 || true

if [[ -s "$WTS_SMOKE_LOCKY" ]]; then
  print -r -- "     these calls may take index.lock:"
  sed 's/^/       git /' "$WTS_SMOKE_LOCKY"
  fail "no collector git call may take index.lock"
else
  ok "no collector git call may take index.lock"
fi

# ─── Stop and restore ────────────────────────────────────────────────────────
# `wts stop` leaves exactly the state `wts restore` replays: tmux session gone,
# everything else kept. The current-session refusal is not exercised here: TMUX
# is unset and no client is attached, so `#S` would only name the last session
# used.

"$WTS" stop auth-form >/dev/null
refute "stop kills the session" has_session auth-form
check "stop keeps the worktree" test -d "$WT/auth-form"
check "stop keeps the branch" git show-ref --verify --quiet refs/heads/feature/auth-form
check "stop keeps the registry entry" in_registry auth-form
check "a stopped session reads stopped in the switcher" \
  eval '"$WTS" status --fzf | awk -F "\037" "\$1 == \"auth-form\" && \$2 == \"stopped\" { ok = 1 } END { exit !ok }"'
check "switcher list keeps 3 fields with a stopped session" \
  eval '"$SWITCH" --list | awk -F "\t" "NF != 3 { exit 1 }"'
refute "stop of an unknown session fails" "$WTS" stop nope
refute "stop of a stopped session fails" "$WTS" stop auth-form
"$WTS" restore auth-form >/dev/null
check "restore restarts a stopped session" has_session auth-form

# No git call in `stop`: the switcher popup runs it from wherever tmux started.
check "stop needs no git repository" eval '(cd / && "$WTS" stop auth-form >/dev/null)'
refute "stop from outside the repository kills the session" has_session auth-form
"$WTS" restore auth-form >/dev/null
check "restore after a second stop" has_session auth-form

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

# ─── gc: stale index.lock ────────────────────────────────────────────────────
# A git process killed mid-operation leaves <gitdir>/index.lock behind and every
# later write in that worktree fails, silently until the next `git add`.
# WTS_LOCK_STALE_AFTER=0 so the test does not sit out the 5-minute default.

survivor="$WT/export-users-csv"
lockdir=$(git -C "$survivor" rev-parse --path-format=absolute --git-dir)
: > "$lockdir/index.lock"
refute "the stale lock blocks git add" git -C "$survivor" add -A
# Matched on the captured output, not through `| grep -q`: grep exits on the
# first match, gc dies of SIGPIPE and `set -o pipefail` fails the whole check.
check "gc reports the stale lock" eval '
  out=$(WTS_LOCK_STALE_AFTER=0 "$WTS" gc --no-fetch)
  [[ "$out" == *"Stale index.lock ("*"export-users-csv"* ]]'
check "the dry run keeps it" test -f "$lockdir/index.lock"

WTS_LOCK_STALE_AFTER=0 "$WTS" gc --no-fetch --apply >/dev/null
refute "gc --apply removes it" test -f "$lockdir/index.lock"
check "git add works again" git -C "$survivor" add -A

# A lock with content is a write in progress: git fills it before renaming it
# over `index`, so removing it would truncate somebody's index.
print -n busy > "$lockdir/index.lock"
WTS_LOCK_STALE_AFTER=0 "$WTS" gc --no-fetch --apply >/dev/null
check "a non-empty lock is left alone" test -s "$lockdir/index.lock"
rm -f "$lockdir/index.lock"

check "a fresh lock is left alone" eval '
  : > "$lockdir/index.lock"
  "$WTS" gc --no-fetch --apply >/dev/null
  test -f "$lockdir/index.lock"'
rm -f "$lockdir/index.lock"

# ─── rm ──────────────────────────────────────────────────────────────────────

"$WTS" rm export-users-csv -f >/dev/null
refute "rm kills the session" has_session export-users-csv
refute "rm removes the worktree" test -d "$WT/export-users-csv"
refute "rm deletes the branch" git show-ref --verify --quiet refs/heads/feature/export-users-csv
refute "rm drops the registry entry" in_registry export-users-csv

# ─── Stale local base ────────────────────────────────────────────────────────
# Last, and only now: giving the repo a remote changes what `wts gc` compares
# against, so it must not happen while the checks above are running.
#
# wts-fresh cuts branches from origin/<base>, so the delta has to be measured
# against origin/<base> too. Measured against a local base left behind, a branch
# with no commits of its own was credited with everything the local base was
# missing (+91727/-28066 and ^333, on the repository that motivated this).

ORIGIN="$SANDBOX/code/origin.git"
git init -q --bare "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
lagging=$(git -C "$REPO" rev-parse main)
print upstream > "$REPO/UPSTREAM"
git -C "$REPO" add UPSTREAM
git -C "$REPO" commit -qm upstream
git -C "$REPO" push -q origin main
git -C "$REPO" remote set-head origin -a    # so detect_base finds origin/HEAD
git -C "$REPO" reset -q --hard "$lagging"   # local main now trails origin/main

# WTS_BASE_BRANCH only for this call, exactly as wts-fresh passes it: the
# collector below must rediscover the base on its own.
WTS_NO_ATTACH=1 WTS_BASE_BRANCH=origin/main "$WTS" fresh-cut smoke >/dev/null
check "session cut from origin/<base>" in_registry fresh-cut

# The branch is origin/main itself, so every counter is zero and it is merged.
# Against the local base it used to report ahead=1 and added=1.
check "delta measured against origin/<base>" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\")
        | .ahead == 0 and .behind == 0 and .added == 0 and .removed == 0"'
check "merged seen through origin/<base>" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\") | .merged"'
# Pins the contract: wts-brief reads .base and derives "origin/$base" itself, so
# it must stay the short name.
check "base still reports the short name" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\") | .base == \"main\""'

print -r -- "── $passed checks passed"
