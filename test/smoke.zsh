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

# ─── Naming ────────────────────────────────────────────────────────────────────
# Every way the call can fail used to read "Claude unavailable or no answer",
# which made a rejected model id on another machine undiagnosable. The stand-in
# claude reads stdin first: the real one does, and a stub that exits on a full
# pipe would fail the pipeline rather than the call.

NAME="$ROOT/libexec/wts/wts-name"
STUBS="$SANDBOX/name-stubs"
mkdir -p "$STUBS"
name_with() { # <sh-body> [env=value...] — wts-name against that stand-in claude
  local body="$1"; shift
  print -r -- "#!/bin/sh
cat >/dev/null
$body" > "$STUBS/claude"
  chmod +x "$STUBS/claude"
  env PATH="$STUBS:$PATH" WTS_NO_LLM= "$@" "$NAME" "export users as csv" 2>&1
}

check "an answer that is a name becomes the slug" eval '
  [[ "$(name_with "echo fix-csv-export")" == "fix-csv-export" ]]'
check "a rejected model never becomes a branch name" eval '
  out=$(name_with "echo \"There is an issue with the selected model, sorry\"
        echo \"[claude-code:unrecognized_model] {}\" >&2")
  [[ "$out" == *"claude: [claude-code:unrecognized_model]"* \
     && "$out" == *export-users-csv* && "$out" != *selected* ]]'
check "a failing claude reports what it wrote" eval '
  [[ "$(name_with "echo boom >&2; exit 1")" == *"claude: boom"* ]]'
check "a silent failure reports its status" eval '
  [[ "$(name_with "exit 3")" == *"claude exited with status 3"* ]]'
check "a timeout says how long it waited" eval '
  [[ "$(name_with "sleep 3" WTS_NAME_TIMEOUT=1)" == *"no answer in 1s"* ]]'
check "without claude the warning says so" eval '
  [[ "$(env PATH=/usr/bin:/bin WTS_NO_LLM= "$NAME" "export users as csv" 2>&1)" \
     == *"claude not found in PATH"* ]]'
check "WTS_NO_LLM stays silent" eval '
  [[ "$("$NAME" "export users as csv" 2>&1)" == "export-users-csv" ]]'

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

# ─── Keys: the footer and `wts keys` ─────────────────────────────────────────
# Both read wts-keys, so the popup and the terminal can never disagree. The
# footer is as wide as the LIST, not the popup, and fzf cuts what overflows:
# every rendering is checked against the width it was given.
KEYS="$ROOT/libexec/wts/wts-keys"
# The switcher always exports the list's width before fzf starts, so the bind
# subprocesses inherit it; without it wts-keys would size on COLUMNS.
export WTS_SWITCH_COLS=89
# Captured rather than piped into `grep -q`: grep exits on the match, wts-keys
# is still printing, and the SIGPIPE that follows fails the pipeline (pipefail).
check "wts keys lists a switcher key" \
  eval 'out=$("$WTS" keys); [[ "$out" == *"^x"*"keep the worktree"* ]]'
check "wts keys lists the tmux bindings" \
  eval '[[ "$("$WTS" keys)" == *"jump to the next agent"* ]]'
check "the collapsed line always keeps its way back to the list" \
  eval '[[ "$(WTS_SWITCH_COLS=24 "$KEYS" --footer collapsed)" == *"? keys" ]]'
check "a wide list gets the rarest keys too" \
  eval '[[ "$(WTS_SWITCH_COLS=100 "$KEYS" --footer collapsed)" == *"^r reload"* ]]'
check "no footer line is wider than the list" \
  eval 'for w in 24 40 60 89 200; do
          for mode in collapsed expanded reply; do
            while IFS= read -r line; do
              (( ${#line} <= w - 2 )) || exit 1
            done < <(WTS_SWITCH_COLS=$w "$KEYS" --footer $mode)
          done
        done'
check "the expanded list ends with the tmux bindings" \
  eval '[[ "$(WTS_SWITCH_COLS=89 "$KEYS" --footer expanded | tail -1)" == "tmux: "* ]]'
check "the reply footer drops the keys reply mode disables" \
  eval 'line=$(WTS_SWITCH_COLS=89 "$KEYS" --footer reply)
        [[ "$line" == "enter send"* && "$line" != *"^d rm"* ]]'

# --footer is fzf 0.65 and an unknown action closes the popup without a word,
# so the actions are checked against the installed fzf, and nothing that
# mentions the footer may be emitted when WTS_SWITCH_FOOTER is not set.
check "fzf accepts the footer and its bind" \
  eval 'printf "x\n" | fzf --footer=k --bind="?:transform(true)" --filter=x'
export WTS_SWITCH_HELP="$SANDBOX/help"
export WTS_SWITCH_REPLY="$SANDBOX/reply"
export WTS_SWITCH_FOOTER=1
check "? is typed into a filter rather than swallowed by the help" \
  eval '[[ "$("$SWITCH" --keys toggle auth)" == "put(?)" && ! -e "$WTS_SWITCH_HELP" ]]'
chain=$("$SWITCH" --keys toggle "")
check "? expands the footer" \
  eval '[[ -e "$WTS_SWITCH_HELP" ]] && print -r -- "$chain" | grep -q "^change-footer|"'
check "fzf parses the expanded footer chain" fzf_parses "$chain"
check "? collapses it again" \
  eval '"$SWITCH" --keys toggle "" >/dev/null && [[ ! -e "$WTS_SWITCH_HELP" ]]'
chain=$("$SWITCH" --reply toggle auth-form auth-form)
check "reply mode unbinds ? and repaints the footer" \
  eval 'print -r -- "$chain" | grep -qF "unbind(ctrl-d,ctrl-x,?)" &&
        print -r -- "$chain" | grep -qF "change-footer|enter send"'
check "fzf parses the reply chain with its footer" fzf_parses "$chain"
chain=$("$SWITCH" --reply esc)
check "leaving reply mode rebinds ? and puts the list's keys back" \
  eval 'print -r -- "$chain" | grep -qF "rebind(ctrl-d,ctrl-x,?)" &&
        print -r -- "$chain" | grep -qF "change-footer|enter switch"'
check "fzf parses the leave chain with its footer" fzf_parses "$chain"
unset WTS_SWITCH_FOOTER
refute "an fzf without --footer is never handed a change-footer" \
  eval '"$SWITCH" --reply toggle auth-form auth-form | grep -q change-footer'
"$SWITCH" --reply esc >/dev/null
unset WTS_SWITCH_REPLY WTS_SWITCH_HELP WTS_SWITCH_COLS

# ─── pr: ctrl-o and `wts pr` ─────────────────────────────────────────────────
# A stand-in gh: logs where and how it is called, and knows exactly one PR. The
# real gh would hit the network and needs a login; CI has one on PATH, so every
# "without gh" case below runs with a PATH that has nothing but zsh and jq.
export WTS_SMOKE_GH_LOG="$SANDBOX/gh.log"
export WTS_SMOKE_PR_BRANCH="feature/auth-form"
cat > "$SANDBOX/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$PWD" "$*" >> "$WTS_SMOKE_GH_LOG"
if [ "$1" = pr ] && [ "$2" = view ] && [ "$3" = "$WTS_SMOKE_PR_BRANCH" ]; then
  echo "Opening https://example.test/pull/1 in your browser."
  exit 0
fi
echo "no pull requests found for branch \"$3\"" >&2
exit 1
EOF
chmod +x "$SANDBOX/bin/gh"
mkdir -p "$SANDBOX/nogh"
ln -s "$(command -v jq)" "$SANDBOX/nogh/jq"
ln -s "$(command -v zsh)" "$SANDBOX/nogh/zsh"

# Exit non-zero, and the message (stdout or stderr) matches.
fails_with() { # <pattern> <cmd...>
  local pat="$1" out; shift
  out=$("$@" 2>&1) && return 1
  print -r -- "$out" | grep -q -- "$pat"
}

check "wts pr opens the pull request of the session's branch" \
  eval '"$WTS" pr auth-form | grep -q "Opening https://example.test/pull/1"'
check "gh runs in the repository, by head branch, with --web" \
  grep -qxF "$REPO	pr view feature/auth-form --web" "$WTS_SMOKE_GH_LOG"
check "a branch without a pull request says so and fails" \
  fails_with "no pull requests found" "$WTS" pr export-users-csv
check "a tmux session wts never created is refused before gh" \
  fails_with "not a wts session" "$WTS" pr "$LONG"
refute "gh was not asked about that session" grep -q "$LONG" "$WTS_SMOKE_GH_LOG"
check "no name outside tmux is a usage error" fails_with "Usage: wts pr" "$WTS" pr
# `env`, not a prefix assignment on fails_with: that would strip grep from the
# helper too.
check "without gh, wts pr says what to install" \
  fails_with "gh not found" env PATH="$SANDBOX/nogh" "$WTS" pr auth-form

# The bind is gated on gh the same way, and the key list follows the bind.
check "fzf accepts the ctrl-o bind" \
  eval 'printf "x\n" | fzf --bind="ctrl-o:execute(true)" --filter=x'
check "the switcher binds ctrl-o to --pr" grep -qF "ctrl-o:execute('\$self' --pr {3})" "$SWITCH"
check "--pr on an empty list is a no-op" eval '[[ -z $("$SWITCH" --pr "" </dev/null) ]]'
check "wts keys lists ctrl-o with gh" eval '"$WTS" keys | grep -F "  ^o " | grep -q "pull request"'
check "wts keys hides ctrl-o without gh, and keeps the rest" \
  eval 'out=$(PATH="$SANDBOX/nogh" "$KEYS") && print -r -- "$out" | grep -q "^  ^x " \
        && ! print -r -- "$out" | grep -q "\^o"'
check "the footer lists ctrl-o when the switcher bound it" \
  eval 'WTS_SWITCH_COLS=89 WTS_SWITCH_PR=1 "$KEYS" --footer collapsed | grep -qF "^o pr"'
refute "the footer hides ctrl-o when it is not bound" \
  eval 'WTS_SWITCH_COLS=89 "$KEYS" --footer collapsed | grep -qF "^o pr"'
check "the footer still fits with ctrl-o" \
  eval 'for w in 24 40 60 89 200; do
          for mode in collapsed expanded reply; do
            while IFS= read -r line; do
              (( ${#line} <= w - 2 )) || exit 1
            done < <(WTS_SWITCH_COLS=$w WTS_SWITCH_PR=1 "$KEYS" --footer $mode)
          done
        done'
check "wts pr is completed" grep -q '"pr:open the session' "$ROOT/completions/_wts"

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
export WTS_SMOKE_BRANCHLOG="$SANDBOX/branch.log"
cat > "$SANDBOX/shim/git" <<'EOF'
#!/bin/sh
# --no-optional-locks and GIT_OPTIONAL_LOCKS come before the subcommand, so
# scanning in order and stopping there sees everything that matters.
for a in "$@"; do
  case "$a" in
    --no-optional-locks) nolocks=1 ;;
    branch)              echo "$*" >> "$WTS_SMOKE_BRANCHLOG" ;;
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

# The per-repository memo of `branch --merged` used to be lost in a subshell,
# so the call ran once per session: with two sessions in one repository, one
# pass must run it exactly once.
: > "$WTS_SMOKE_BRANCHLOG"
PATH="$SANDBOX/shim:$PATH" "$WTS" status --json >/dev/null 2>&1 || true
check "one pass runs branch --merged once per repository" \
  eval '[[ "$(grep -c -- "--merged" "$WTS_SMOKE_BRANCHLOG")" == 1 ]]'

# --no-git: agent and tmux columns only, git columns "-", same field count.
check "status --fzf --no-git keeps 7 fields" \
  eval '"$ROOT/libexec/wts/wts-status" --fzf --no-git | awk -F "\037" "NF != 7 { exit 1 }"'
check "status --fzf --no-git shows - for delta and dirty" \
  eval '"$ROOT/libexec/wts/wts-status" --fzf --no-git | awk -F "\037" "\$4 != \"-\" || \$5 != \"-\" { exit 1 }"'
check "status --json --no-git lists every session with zeroed git columns" \
  eval '"$ROOT/libexec/wts/wts-status" --json --no-git | jq -e "length == 2 and all(.[]; .dirty == 0 and .added == 0 and .exists)"'
check "status --json <name> collects that session only" \
  eval '"$ROOT/libexec/wts/wts-status" --json auth-form | jq -e "length == 1 and .[0].name == \"auth-form\""'
check "switch --list --no-git renders" eval '"$SWITCH" --list --no-git | grep -q "auth-form"'
check "setup git prints the fsmonitor settings" \
  eval '"$WTS" setup git | grep -q "core.fsmonitor true"'

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
