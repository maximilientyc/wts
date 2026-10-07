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
# The hooks record events here; they must not ring a bell or post a banner.
export WTS_NOTIFY=0
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
[ "$1" = --version ] && { echo "${WTS_SMOKE_CLAUDE_VERSION:-0.0.0} (smoke stand-in)"; exit 0; }
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
# A line sent to a shell pane takes a moment to run and print: poll up to 10 s.
# The pane runs your interactive zsh, rc files and all: 0.3 s alone, and past
# the 3 s this used to allow on a machine busy with other agents, which failed
# `restore pre-fills the conversation` now and then. Only a failure waits longer.
pane_shows() { # <session> <line>
  local i
  for i in {1..100}; do
    tmux capture-pane -p -t "=$1:" 2>/dev/null | grep -qx -- "$2" && return 0
    sleep 0.1
  done
  return 1
}
# Like pane_shows, but for text the pane only displays: a line typed at a
# prompt carries the prompt as a prefix, so the match cannot be anchored.
pane_contains() { # <session> <text>
  local i
  for i in {1..30}; do
    tmux capture-pane -pJ -t "=$1:" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1
  done
  return 1
}
DB="$XDG_STATE_HOME/wts/wts.db"
q() { sqlite3 -init /dev/null "$DB" "$@" }
in_registry() { [[ "$(q "SELECT count(*) FROM sessions WHERE name = '$1'")" == 1 ]] }
reg_field() { q "SELECT $2 FROM sessions WHERE name = '$1'" }   # <session> <column>
doc_cached() { [[ -n "$(q "SELECT 1 FROM doc_cache WHERE slug = '$1' AND length(body) > 0")" ]] }

# ─── CLI surface ─────────────────────────────────────────────────────────────

check "version" eval '[[ "$("$WTS" --version)" == "wts "[0-9]* ]]'
check "help exits 0" "$WTS" --help
refute "unknown option fails" "$WTS" --bogus

# One usage per command, cut from the header `wts help` prints: `wts new --help`
# used to start a session named `--help`.
check "help <command> prints that command's usage" eval '
  out=$("$WTS" help rm); [[ "$out" == "usage: wts rm <name> [-f]"* && "$out" == *"-f       : force"* ]]'
check "<command> --help prints the same, exit 0" eval '[[ "$("$WTS" rm --help)" == "$("$WTS" help rm)" ]]'
check "--help after other arguments too" eval '[[ "$("$WTS" gc --apply --help)" == "usage: wts gc "* ]]'
check "a usage spread over two lines is kept whole" eval '
  out=$("$WTS" log --help); [[ "$out" == *"[--no-notes] [--no-things]"* ]]'
check "ls refuses an argument instead of dropping it" eval '"$WTS" ls --json 2>/dev/null; (( $? == 2 ))'
check "setup tmux prints absolute helper paths" \
  eval 'out=$("$WTS" setup tmux); [[ "$out" == *"$ROOT/libexec/wts/wts-fresh"* ]]'
check "layouts lists the user layout" eval '"$WTS" layouts | grep -q "^smoke	"'
check "layouts lists the built-in default" eval '"$WTS" layouts | grep -qF "default	$ROOT/share/wts/layouts/default.yml"'

# The built-in layout renders, fresh and restored, with and without a context
# document, and with a phrase that needs escaping. This is the guard on the two
# layers of escaping the claude pane goes through (Ruby's shellescape for the
# pane's shell, then tmuxinator's own for send-keys) and on the YAML quoting of
# the restore pre-fill: a backslash in a double-quoted scalar stops the file
# from parsing at all.
# Directly, not through wts: bin/wts is a zsh script, so a ~/.zshenv that
# exports EDITOR overrides the one given here and hides the case. Bare in the
# YAML, `true` was a boolean and tmuxinator failed on it.
check "an EDITOR that reads as a YAML boolean renders as a command" eval '
  out=$(env EDITOR=true WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE= \
          WTS_DOC= WTS_PROMPT= tmuxinator debug --suppress-tmux-version-warning \
          --project-config "$ROOT/share/wts/layouts/default.yml" 2>&1)
  [[ "$out" == *"send-keys -t render:0.0 true C-m"* ]]'
for restore in "" 1; do
  for doc in "" ".wts/context.md"; do
    check "default layout renders (restore=${restore:-0}, doc=${doc:-none})" env \
      WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE="$restore" \
      WTS_DOC="$doc" WTS_PROMPT="it's a test; ok" \
      tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml"
  done
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
"$WTS" new --help >/dev/null
refute "new --help creates no worktree" test -e "$WT/--help"
check "a name followed by --help prints the usage" eval '[[ "$("$WTS" auth-form --help)" == *"Usage: wts "* ]]'
refute "and creates nothing" test -e "$WT/auth-form"

# A typo of a command is not a new piece of work.
check "a typo of a command is refused, exit 2" eval '"$WTS" lsit 2>/dev/null; (( $? == 2 ))'
check "it names the command" eval '[[ "$("$WTS" statsu 2>&1)" == *"did you mean '\''wts status'\''"* ]]'
refute "and creates no worktree or branch" eval '
  test -e "$WT/lsit" || git show-ref --quiet refs/heads/lsit || git show-ref --quiet refs/heads/feature/lsit'
check "a word that is no near-command stays a session name" eval '
  out=$(cd / && "$WTS" lint 2>&1); [[ "$out" == *"not a git repository"* ]]'
check "a second word says it is meant" eval '
  out=$(cd / && "$WTS" lsit smoke 2>&1); [[ "$out" == *"not a git repository"* ]]'

# ─── Create ──────────────────────────────────────────────────────────────────

WTS_NO_ATTACH=1 "$WTS" auth-form smoke >/dev/null
check "worktree created" test -d "$WT/auth-form"
check "branch prefix from the layout" git show-ref --verify --quiet refs/heads/feature/auth-form
check "tmux session started" has_session auth-form
check "session registered" in_registry auth-form

WTS_NO_ATTACH=1 "$WTS" "export users as csv" smoke >/dev/null
check "name derived locally from a phrase" has_session export-users-csv
check "phrase stored in the registry" \
  eval '[[ "$(reg_field export-users-csv prompt)" == "export users as csv" ]]'
check "phrase written to .wts/prompt" \
  eval '[[ "$(<"$WT/export-users-csv/.wts/prompt")" == "export users as csv" ]]'
check "and ignored by git" eval '[[ -z "$(git -C "$WT/export-users-csv" status --porcelain)" ]]'

# .worktreeinclude: untracked files of the main checkout copied into a new
# worktree, matched by that file's rules alone (.gitignore has its say on the
# candidates, not on the match). Nothing without the file.
# The commit is undone below: later tests fast-forward main to a clone's.
printf '%s\n' '.env' 'config/' > .gitignore
git add .gitignore && git commit -qm 'ignore .env and config/'
print 'TOKEN=1' > .env
print 'SECRET=1' > secret.env
mkdir -p config && print 'local: 1' > config/local.yml
WTS_NO_ATTACH=1 "$WTS" noinclude smoke >/dev/null
refute "without .worktreeinclude nothing is copied" eval 'test -e "$WT/noinclude/.env" || test -e "$WT/noinclude/secret.env" || test -e "$WT/noinclude/config"'
"$WTS" rm noinclude -f >/dev/null
printf '%s\n' '*.env' '!secret.env' 'config/' > .worktreeinclude
out=$(WTS_NO_ATTACH=1 "$WTS" withinclude smoke 2>&1)
check ".worktreeinclude copies a matching ignored file" eval '[[ "$(<"$WT/withinclude/.env")" == "TOKEN=1" ]]'
check "and a nested one, its folder created" eval '[[ "$(<"$WT/withinclude/config/local.yml")" == "local: 1" ]]'
check "and says how many" eval '[[ "$out" == *".worktreeinclude: 2 file(s) copied"* ]]'
check "which stay untracked (ignored)" eval '[[ -z "$(git -C "$WT/withinclude" status --porcelain)" ]]'
refute "a negated file is not copied" test -e "$WT/withinclude/secret.env"
"$WTS" rm withinclude -f >/dev/null
rm -rf .env secret.env config .worktreeinclude
git reset -q --hard HEAD~1

# A long phrase reaches claude whole. The layout used to type `claude '<phrase>'`
# into the pane before its shell was ready: the tty, still in canonical mode,
# kept 1024 bytes of the line, the closing quote was lost and claude never
# started. The built-in layout runs here with the stand-in named by absolute
# path (the pane's login shell rebuilds PATH), which logs what it was given.
cat > "$SANDBOX/claude-logger" <<EOF
#!/bin/sh
printf '%s' "\$*" > "$SANDBOX/claude-arg"
exec sleep 3600
EOF
chmod +x "$SANDBOX/claude-logger"
sed -e "s#? 'claude' : \"claude #? '$SANDBOX/claude-logger' : \"$SANDBOX/claude-logger #" \
    -e 's#^name: #tmux_options: -f /dev/null\nname: #' \
    "$ROOT/share/wts/layouts/default.yml" > "$XDG_CONFIG_HOME/wts/layouts/longp.yml"
long=$(perl -e 'print join(" ", map { "step $_: keep the \$HOME, the `ticks` and \"quotes\" (it'"'"'s fine);" } 1..30)')
claude_got() { # <text> — the stand-in was started with exactly that argument
  local i
  for i in {1..100}; do
    [[ -s "$SANDBOX/claude-arg" ]] && break
    sleep 0.1
  done
  [[ "$(cat "$SANDBOX/claude-arg" 2>/dev/null)" == "$1" ]]
}
check "the long phrase is over the tty's 1024-byte line" eval '(( ${#long} > 1024 ))'
EDITOR=true WTS_NO_ATTACH=1 "$WTS" longp "$long" longp >/dev/null
# The session's name comes first, as the conversation's (--name).
check "a long phrase reaches claude whole, after the session's name" claude_got "--name longp $long"
"$WTS" rm longp -f >/dev/null
rm -f "$SANDBOX/claude-arg"
# The line each layout types, replayed in a shell: a path with a space and a
# quote, and the context document's lead sentence before the phrase.
mkdir -p "$SANDBOX/pf dir"
print -r -- "it's a \$HOME test; ok" > "$SANDBOX/pf dir/it's"
typed_arg() { # <layout> [env=value...] — what the claude pane receives as its arguments
  local layout="$1" out line
  shift
  out=$(env WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE= WTS_DOC= \
          WTS_PROMPT="it's a test; ok" WTS_PROMPT_FILE="$SANDBOX/pf dir/it's" "$@" \
          tmuxinator debug --suppress-tmux-version-warning --project-config "$layout") || return 1
  line=${${(M)${(f)out}:#*send-keys -t render:0.1 *}[1]}
  line=${${line#*render:0.1 }% C-m}
  [[ "$line" == *'$\(cat'* ]] || return 1     # read from the file, not typed
  line=$(eval "print -r -- $line")              # the layer tmuxinator adds
  zsh -fc "claude() { print -r -- \"\$*\" }; $line"
}
check "the default layout reads the phrase file, after the document's lead" eval '
  [[ "$(typed_arg "$ROOT/share/wts/layouts/default.yml" WTS_DOC=.wts/context.md)" \
     == "--name render Read @.wts/context.md first, it is the context for this task. it'"'"'s a \$HOME test; ok" ]]'
for ex in feature sentry; do
  check "examples/$ex reads the phrase file" eval '
    [[ "$(typed_arg "$ROOT/examples/layouts/$ex.yml")" == "--name render it'"'"'s a \$HOME test; ok" ]]'
done

# tmux makes `v1.2` a session `v1_2`: `has-session -t "=v1.2"` then never
# matched, and each re-run started a duplicate. Refused with a usable name.
check "a session name with . or : is refused, with the name to use" eval '
  out=$(env WTS_NO_ATTACH=1 "$WTS" v1.2 smoke 2>&1); rc=$?
  (( rc == 2 )) && [[ "$out" == *"tmux rewrites"*"wts v1-2"* ]] \
  && ! git show-ref --quiet refs/heads/feature/v1.2 && [[ ! -e "$WT/v1.2" ]]'
refute "and so is one with a colon" env WTS_NO_ATTACH=1 "$WTS" "a:b" smoke
refute "missing layout fails" env WTS_NO_ATTACH=1 "$WTS" other nope
refute "missing layout creates nothing" test -e "$WT/other"

# tmuxinator's own reason, not "failed to start" alone.
print -r -- $'name: <%= ENV[\'WTS_NAME\'] %>\nroot: <%= ENV[\'WTS_WORKDIR\'] %>\nwindows: [unclosed' \
  > "$XDG_CONFIG_HOME/wts/layouts/broken.yml"
check "a layout tmuxinator rejects is reported with its reason" eval '
  out=$(WTS_NO_ATTACH=1 "$WTS" brokenl broken 2>&1 >/dev/null)
  [[ "$out" == *"tmuxinator failed to start — "?* ]]'
"$WTS" rm brokenl -f >/dev/null 2>&1 || true
rm -f "$XDG_CONFIG_HOME/wts/layouts/broken.yml"

# Without tmuxinator nothing is created: it was found missing by the last line,
# after the worktree and the registry row existed.
nomux="$SANDBOX/nomux"
mkdir -p "$nomux"
for t in git tmux sqlite3 jq perl zsh awk sed grep head cut tr wc mktemp dirname basename date; do
  p=$(command -v $t) && ln -sf "$p" "$nomux/$t"
done
check "without tmuxinator, wts says so and creates nothing" eval '
  out=$(env PATH="$nomux" WTS_NO_ATTACH=1 "$WTS" nomuxsess smoke 2>&1)
  [[ "$out" == *"tmuxinator not found — nothing was created"* ]] && [[ ! -e "$WT/nomuxsess" ]]'
# A version manager's shim whose Ruby is missing: on PATH, exits 126, says
# nothing. Found while recording this: "failed to start" with no reason at all.
badmux="$SANDBOX/badmux"
mkdir -p "$badmux"
print -r -- $'#!/bin/sh\nexit 126' > "$badmux/tmuxinator"
chmod +x "$badmux/tmuxinator"
check "a tmuxinator that fails in silence is reported by its status" eval '
  out=$(env PATH="$badmux:$PATH" WTS_NO_ATTACH=1 "$WTS" silentmux smoke 2>&1)
  [[ "$out" == *"tmuxinator failed to start — exit status 126"* ]]'
"$WTS" rm silentmux -f >/dev/null 2>&1 || true

# ─── Naming ────────────────────────────────────────────────────────────────────
# Every way the call can fail used to read "Claude unavailable or no answer",
# which made a rejected model id on another machine undiagnosable. The stand-in
# claude reads stdin first: the real one does, and a stub that exits on a full
# pipe would fail the pipeline rather than the call.

# stub_claude <dir> <sh-body> — a stand-in claude in <dir> whose answer is
# what <sh-body> prints, run with claude's arguments and its stdin. With
# `--output-format json` (what wts-name, wts-brief and wts-retro pass) it
# answers as the real one does: one JSON result, the text turned into
# .structured_output — its "label: value" lines as fields, or else its first
# line as {name} — with a usage and a cost (0.0004 on claude-haiku-5-5, a
# model usage_cost_sql has no price for). Without the flag the text comes back
# as is, which no caller can read any more. A body that prints a JSON object
# answers that object, for the error shapes.
stub_claude() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  print -r -- "$body" > "$dir/answer"
  cat > "$dir/claude" <<'STUB'
#!/bin/sh
input=$(cat)
out=$(printf '%s\n' "$input" | sh "$(dirname "$0")/answer" "$@"); rc=$?
case " $* " in
  *" --output-format json "*) ;;
  *) [ -n "$out" ] && printf '%s\n' "$out"; exit $rc ;;
esac
[ -n "$out" ] || exit $rc
case "$out" in
  "{"*) printf '%s\n' "$out"; exit $rc ;;
esac
jq -cn --arg t "$out" '
  ($t | split("\n") | map(capture("^(?<key>[a-z]+): (?<value>.*)$")?) | from_entries) as $o
  | {type: "result", subtype: "success", is_error: false, result: $t,
     structured_output: (if ($o | length) > 0 then $o else {name: ($t | split("\n")[0])} end),
     total_cost_usd: 0.0004,
     usage: {input_tokens: 10, output_tokens: 20, cache_creation_input_tokens: 100,
             cache_read_input_tokens: 0, cache_creation: {ephemeral_1h_input_tokens: 100},
             speed: "standard"},
     modelUsage: {"claude-haiku-5-5": {costUSD: 0.0004}}}'
exit $rc
STUB
  chmod +x "$dir/claude"
}

NAME="$ROOT/libexec/wts/wts-name"
STUBS="$SANDBOX/name-stubs"
name_with() { # <sh-body> [env=value...] — wts-name against that stand-in claude
  stub_claude "$STUBS" "$1"; shift
  env PATH="$STUBS:$PATH" WTS_NO_LLM= "$@" "$NAME" "export users as csv" 2>&1
}

check "an answer that is a name becomes the slug" eval '
  [[ "$(name_with "echo fix-csv-export")" == "fix-csv-export" ]]'
check "the name is asked as JSON, against a schema" eval '
  name_with "printf \"%s\n\" \"\$*\" > \"$STUBS/args\"; echo fix-csv-export" >/dev/null
  args=$(<"$STUBS/args")
  [[ "$args" == *"--output-format json"* && "$args" == *"--json-schema"*"\"name\""* ]]'
check "a sentence in the name field never becomes a branch name" eval '
  out=$(name_with "echo \"There is an issue with the selected model, sorry\"
        echo \"[claude-code:unrecognized_model] {}\" >&2")
  [[ "$out" == *"claude: [claude-code:unrecognized_model]"* \
     && "$out" == *export-users-csv* && "$out" != *selected* ]]'
# What the real one answers for a model it does not know: exit 1, is_error, the
# reason in .result, nothing on stderr when --verbose is off.
check "an error result names the reason claude gave" eval '
  out=$(name_with "echo '"'"'{\"type\":\"result\",\"is_error\":true,\"result\":\"There is an issue with the selected model (x).\",\"structured_output\":null}'"'"'; exit 1")
  [[ "$out" == *"claude: There is an issue with the selected model (x)."* && "$out" == *export-users-csv ]]'
check "and so does a budget reached" eval '
  out=$(name_with "echo '"'"'{\"type\":\"result\",\"is_error\":true,\"subtype\":\"error_max_budget_usd\",\"errors\":[\"Reached maximum budget\"]}'"'"'; exit 1")
  [[ "$out" == *"claude: Reached maximum budget"* ]]'
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

# The call's cost, attached to the session the name creates: wts-name runs
# before the row exists, so wts records it right after registry_put.
stub_claude "$STUBS" "echo price-the-name"
env PATH="$STUBS:$PATH" WTS_NO_LLM= WTS_NO_ATTACH=1 "$WTS" "count what naming costs" smoke >/dev/null 2>&1
check "naming records its cost under the session it named" eval '
  [[ "$(q "SELECT model || '\''|'\'' || cost_usd || '\''|'\'' || messages || '\''|'\'' || output
           FROM usage WHERE session = '\''price-the-name'\'' AND transcript = '\''wts:name'\''")" \
     == "claude-haiku-5-5|0.0004|1|20" ]]'
check "and status --json counts it, at the price claude reported" eval '
  "$WTS" status --json price-the-name | jq -e ".[0].usage | .cost_usd == 0.0004 and .cost_complete"'
"$WTS" rm price-the-name -f >/dev/null 2>&1

# Ctrl-C while the model names the session: the name comes from the phrase and
# the creation goes on. It used to abort everything. A real Ctrl-C, typed into a
# pane at an interactive shell, so it reaches the whole foreground process group
# as the terminal sends it; the stand-in claude never answers.
print -r -- $'#!/bin/sh\ncat >/dev/null\nexec sleep 60' > "$STUBS/claude"
chmod +x "$STUBS/claude"
# A script, and only its path typed: the command with this PATH spelled out is
# longer than a terminal line accepts, and the tty cut it.
print -r -- "#!/bin/sh
export PATH='$STUBS:$PATH' WTS_NO_LLM= WTS_NO_ATTACH=1
exec '$WTS' 'archive old invoices' smoke" > "$SANDBOX/namer.sh"
chmod +x "$SANDBOX/namer.sh"
tmux new-session -d -s namer -x 160 -y 20 -c "$REPO" "zsh -f -i"
tmux send-keys -t "=namer:" "$SANDBOX/namer.sh; echo rc=\$?" Enter
check "naming says Ctrl-C cuts it short" pane_contains namer "Ctrl-C: derive it from the phrase now"
tmux send-keys -t "=namer:" C-c
check "Ctrl-C while naming takes the local name" pane_contains namer "naming interrupted after"
check "and the creation goes on" pane_contains namer "rc=0"
check "under the name from the phrase" has_session archive-old-invoices
tmux kill-session -t "=namer" 2>/dev/null || true
"$WTS" rm archive-old-invoices -f >/dev/null

# ─── Inspect ─────────────────────────────────────────────────────────────────

check "ls shows the session" eval '"$WTS" ls | grep -q "^auth-form "'
check "status --json" eval '"$WTS" status --json | jq -e "length == 2 and all(.[]; .exists and .tmux_alive)"'
check "status --fzf has 12 fields" eval '"$WTS" status --fzf | awk -F "\037" "NF != 12 { exit 1 }"'

# An interactive agent waiting for an answer needs a human: blocked, sorted first.
jq -n --arg cwd "$WT/export-users-csv" \
  '[{kind: "interactive", status: "waiting", cwd: $cwd, sessionId: "smoke"}]' > "$WTS_SMOKE_AGENTS"
check "waiting agent shown as blocked, first" \
  eval '"$WTS" status --json | jq -e ".[0].name == \"export-users-csv\" and .[0].agent_state == \"blocked\""'
WAITING_AGENT=$(cat "$WTS_SMOKE_AGENTS")

# A state outside the closed list `status --json` promises is null, not passed
# through to the agents that read the contract, and named once by doctor.
jq -n --arg cwd "$WT/export-users-csv" \
  '[{kind: "interactive", status: "pondering", cwd: $cwd, sessionId: "smoke"}]' > "$WTS_SMOKE_AGENTS"
check "an unknown agent state is null in status --json" eval '
  "$WTS" status --json | jq -e "map(select(.name == \"export-users-csv\"))[0].agent_state == null"'
check "and doctor names it" eval '
  out=$("$WTS" doctor 2>&1); [[ "$out" == *"state wts does not know (pondering)"* ]]'
q "DELETE FROM kv WHERE key LIKE 'agent_state.unknown:%'"

# The stale guard on a pane tmux cannot capture (the agent's pane is gone): the
# empty capture hashed the same every tick and read `stuck?` for good.
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
print -r -- '{"sessionId": "smoke", "tmux": "gone:@99.%9999"}' > "$CLAUDE_CONFIG_DIR/sessions/99999.json"
jq -n --arg cwd "$WT/export-users-csv" \
  '[{kind: "interactive", status: "busy", cwd: $cwd, sessionId: "smoke"}]' > "$WTS_SMOKE_AGENTS"
check "a pane that cannot be captured never reads stuck?" eval '
  WTS_STALE_AFTER=0 "$WTS" status --json >/dev/null
  WTS_STALE_AFTER=0 "$WTS" status --json \
    | jq -e "map(select(.name == \"export-users-csv\"))[0] | .agent_state == \"working\" and .stale == false"'
check "and stores no hash for it" eval '[[ "$(q "SELECT count(*) FROM pane_hashes WHERE agent_session = '\''smoke'\''")" == 0 ]]'
rm -f "$CLAUDE_CONFIG_DIR/sessions/99999.json"
print -r -- "$WAITING_AGENT" > "$WTS_SMOKE_AGENTS"

# The skeleton fzf opens on must be interchangeable with the collected list:
# 3 TAB fields, and the same sessions, or the swap would drop or shift rows.
check "switcher list has 3 fields" \
  eval '"$SWITCH" --list | awk -F "\t" "NF != 3 { exit 1 }"'
check "skeleton has 3 fields" \
  eval '"$SWITCH" --list-fast | awk -F "\t" "NF != 3 { exit 1 }"'
check "skeleton lists the same sessions" \
  eval 'diff <("$SWITCH" --list-fast | cut -f3 | sort) <("$SWITCH" --list | cut -f3 | sort)'
# Both go through emit, with widths measured on the same registry: if they ever
# disagree, every column redraws shifted at the swap. The column titles are the
# second line of each list (the counts come first), so equal titles means equal
# widths.
check "skeleton aligns with the collected list" \
  eval 'diff <("$SWITCH" --list-fast | sed -n 2p) <("$SWITCH" --list | sed -n 2p)'

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

# ─── View (ctrl-g) ───────────────────────────────────────────────────────────
# The first header line counts the sessions per agent state, and ctrl-g keeps
# only the ones that need you. The toggle re-emits the last pass's rows
# (--list-cached) rather than collecting again.
export WTS_SWITCH_VIEW="$SANDBOX/view" WTS_SWITCH_ROWS="$SANDBOX/rows"
check "the first header line counts the sessions per state" eval '
  l=$("$SWITCH" --list); [[ "${l%%$'\''\n'\''*}" == "all 2: 1 blocked  ^g needs you "* ]]'
check "the skeleton counts them, states unknown" eval '
  l=$("$SWITCH" --list-fast); [[ "${l%%$'\''\n'\''*}" == "all 2 "* ]]'
check "fzf accepts the ctrl-g bind" \
  eval 'printf "x\n" | fzf --bind="ctrl-g:transform(true)" --filter=x'
chain=$("$SWITCH" --view toggle)
check "ctrl-g turns the view on, on disk" test -e "$WTS_SWITCH_VIEW"
check "and re-emits the cached rows under a new prompt" eval '
  [[ "$chain" == "reload("*"--list-cached)+change-prompt(needs you> )+first" ]]'
check "fzf parses the ctrl-g chain" eval 'printf "x\n" | fzf --bind="start:$chain" --filter=x'
check "the view keeps only the sessions that need you" eval '
  [[ "$("$SWITCH" --list-cached | tail -n +3 | cut -f3)" == export-users-csv ]]'
check "and says so, with what it hides" eval '
  l=$("$SWITCH" --list-cached); [[ "${l%%$'\''\n'\''*}" == "needs you 1/2: 1 blocked  ^g all "* ]]'
check "the collected list keeps the view" eval '
  [[ "$("$SWITCH" --list | tail -n +3 | cut -f3)" == export-users-csv ]]'
check "the view keeps the columns of every row" eval '
  diff <("$SWITCH" --list-cached | sed -n 2p) <("$SWITCH" --list-fast | sed -n 2p)'
check "filtered rows are padded and have 3 fields" eval '
  WTS_SWITCH_COLS=60 "$SWITCH" --list-cached | same_width 60 \
  && "$SWITCH" --list-cached | awk -F "\t" "NF != 3 { exit 1 }"'
check "the skeleton ignores the view" eval '
  [[ $("$SWITCH" --list-fast | tail -n +3 | wc -l) -eq 2 ]]'
check "leaving reply mode keeps the view's prompt" eval '
  [[ "$(WTS_SWITCH_REPLY="$SANDBOX/no-reply" "$SWITCH" --reply leave)" == *"change-prompt(needs you> )"* ]]'
chain=$("$SWITCH" --view toggle)
check "ctrl-g again shows every row" eval '
  [[ ! -e "$WTS_SWITCH_VIEW" && "$chain" == *"change-prompt(session> )"* \
     && $("$SWITCH" --list-cached | tail -n +3 | wc -l) -eq 2 ]]'
check "ctrl-g is in the key table" eval '
  out=$("$ROOT/libexec/wts/wts-keys"); [[ "$out" == *$'\''\n'\''"  ^g      only what needs you"* ]]'
unset WTS_SWITCH_VIEW WTS_SWITCH_ROWS

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
# A session named like a window index: a bare `-t 1` is window 1 of the current
# session (here the most recent one) before it is the session `1`. Both the
# preview and --fit showed the decoy's window.
tmux new-session -d -s 1 -x 100 -y 24 "echo right-session; exec sleep 600"
tmux new-session -d -s numdecoy -x 70 -y 24 "exec sleep 600"
tmux new-window -d -t "=numdecoy:1" "echo wrong-window; exec sleep 600"
pane_shows 1 right-session || true
check "--fit sizes a session named 1, not window 1" \
  eval '[[ "$(FZF_COLUMNS=400 "$SWITCH" --fit 1 1)" == "change-preview-window(right,100,border-left)" ]]'
check "the preview shows a session named 1, not window 1" \
  eval 'out=$("$SWITCH" --preview 1 1); [[ "$out" == *right-session* && "$out" != *wrong-window* ]]'
tmux kill-session -t "=1"; tmux kill-session -t "=numdecoy"

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
# No agent pane known yet: the reply is refused, the text stays in the query,
# and nothing reaches the session's active pane (the editor, in a real layout).
check "a reply with no known agent pane is refused" \
  eval '[[ $("$SWITCH" --reply send "echo wts-reply-refused" auth-form auth-form) == "change-prompt("*"not sent> )" ]]'
refute "and nothing was typed" pane_contains auth-form wts-reply-refused
# What the agent's hooks record from its own environment ($TMUX_PANE).
q "INSERT OR REPLACE INTO agent_panes (session, claude_session, pane, at) VALUES ('auth-form', '', '$(tmux display-message -p -t "=auth-form:" '#{pane_id}')', strftime('%s','now'))"
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
  eval 'print -r -- "$chain" | grep -q "^enable-search+.*rebind(ctrl-d,ctrl-x,ctrl-e,ctrl-t,ctrl-g)" && [[ ! -e "$WTS_SWITCH_REPLY" ]]'
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
  eval 'print -r -- "$chain" | grep -qF "unbind(ctrl-d,ctrl-x,ctrl-e,ctrl-t,ctrl-g,?)" &&
        print -r -- "$chain" | grep -qF "change-footer|enter send"'
check "fzf parses the reply chain with its footer" fzf_parses "$chain"
chain=$("$SWITCH" --reply esc)
check "leaving reply mode rebinds ? and puts the list's keys back" \
  eval 'print -r -- "$chain" | grep -qF "rebind(ctrl-d,ctrl-x,ctrl-e,ctrl-t,ctrl-g,?)" &&
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
# "without gh" case below runs with a PATH that has nothing but zsh, jq and
# sqlite3 (the registry).
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
ln -s "$(command -v sqlite3)" "$SANDBOX/nogh/sqlite3"

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
    branch|for-each-ref|patch-id) echo "$*" >> "$WTS_SMOKE_BRANCHLOG" ;;
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

# Whether a branch landed is the patch-id test now, and it reads diffs: the
# collector keeps its verdict per pair of tips (merge_checks), so a pass over
# tips that did not move asks git for no ancestry and hashes nothing.
"$WTS" status --json >/dev/null 2>&1 || true
: > "$WTS_SMOKE_BRANCHLOG"
PATH="$SANDBOX/shim:$PATH" "$WTS" status --json >/dev/null 2>&1 || true
check "a pass over unchanged tips reads the merge verdict from its cache" \
  eval '! grep -qE -- "--merged|patch-id" "$WTS_SMOKE_BRANCHLOG"'

# --no-git: agent and tmux columns only, git columns "-", same field count.
check "status --fzf --no-git keeps 12 fields" \
  eval '"$ROOT/libexec/wts/wts-status" --fzf --no-git | awk -F "\037" "NF != 12 { exit 1 }"'
check "status --fzf --no-git shows - for delta and dirty" \
  eval '"$ROOT/libexec/wts/wts-status" --fzf --no-git | awk -F "\037" "\$4 != \"-\" || \$5 != \"-\" { exit 1 }"'
check "status --json --no-git lists every session with zeroed git columns" \
  eval '"$ROOT/libexec/wts/wts-status" --json --no-git | jq -e "length == 2 and all(.[]; .dirty == 0 and .added == 0 and .exists)"'
check "status --json <name> collects that session only" \
  eval '"$ROOT/libexec/wts/wts-status" --json auth-form | jq -e "length == 1 and .[0].name == \"auth-form\""'
check "switch --list --no-git renders" eval '"$SWITCH" --list --no-git | grep -q "auth-form"'
check "setup git prints the fsmonitor settings" \
  eval '"$WTS" setup git | grep -q "core.fsmonitor true"'

# ─── Context documents ───────────────────────────────────────────────────────
# All of it under WTS_NO_LLM=1 with a local markdown file: no model is ever
# called, and a URL degrades to a pointer — which is exactly the path a machine
# with no connector takes.

SPEC="$SANDBOX/spec.md"
print -rl -- "# Payments architecture" "" "Webhooks must be idempotent." > "$SPEC"

check "doc add takes a local markdown file" "$WTS" doc add "$SPEC" --name spec
check "the body is cached" doc_cached spec
check "the library entry knows it is a file" \
  jq -e '.docs.spec.kind == "file"' "$XDG_CONFIG_HOME/wts/docs.json"
check "doc ls lists it" eval 'out=$("$WTS" doc ls); [[ "$out" == *spec* ]]'
check "doc show prints the body" \
  eval 'out=$("$WTS" doc show spec); [[ "$out" == *idempotent* ]]'
refute "doc show of an unknown document fails" "$WTS" doc show nope
check "the same source is reused, not twinned" \
  eval 'out=$("$WTS" doc add "$SPEC"); [[ "$out" == *"already in the library"* ]]'
check "a URL with no model becomes a pointer" \
  "$WTS" doc add https://example.invalid/page --name ptr
check "the pointer says so" jq -e '.docs.ptr.kind == "pointer"' "$XDG_CONFIG_HOME/wts/docs.json"

# A fetch bounded by turns and spend: both limits are passed, and reaching one
# (claude prints it on stdout and exits 1) is a failed fetch that names it.
DSTUBS="$SANDBOX/doc-stubs"
doc_with() { # <sh-body> <slug> — wts doc add of a URL against that stand-in
  stub_claude "$DSTUBS" "$1"
  env PATH="$DSTUBS:$PATH" WTS_NO_LLM= WTS_DOC_TOOLS=WebFetch \
    "$WTS" doc add "https://example.invalid/$2" --name "$2" 2>&1
}
check "the fetch passes its budget and its turn limit" eval '
  doc_with "printf \"%s\n\" \"\$*\" > \"$DSTUBS/args\"; echo WTS-FETCH-FAILED: offline" lim0 >/dev/null
  args=$(<"$DSTUBS/args")
  [[ "$args" == *"--max-budget-usd 1 "* && "$args" == *"--max-turns 8 "* ]]'
check "a turn limit reached is a failed fetch that says so" eval '
  out=$(doc_with "printf \"Error: Reached max turns (8)\"; exit 1" lim1)
  [[ "$out" == *"Reached max turns (8) (WTS_DOC_MAX_TURNS)"* \
     && "$(q "SELECT error FROM doc_cache WHERE slug = '"'"'lim1'"'"'")" == *WTS_DOC_MAX_TURNS* ]]'
check "and so is a budget reached" eval '
  out=$(doc_with "printf \"Error: Exceeded USD budget (1)\"; exit 1" lim2)
  [[ "$out" == *"Exceeded USD budget (1) (WTS_DOC_BUDGET_USD)"* ]]'
for d in lim0 lim1 lim2; do "$WTS" doc forget "$d" >/dev/null 2>&1; done

WTS_NO_ATTACH=1 "$WTS" docsess smoke --doc spec >/dev/null
check "--doc writes the context file" test -s "$WT/docsess/.wts/context.md"
check "the document body is in it" grep -q idempotent "$WT/docsess/.wts/context.md"
check "every document is marked with its slug" \
  grep -q "wts-doc: spec" "$WT/docsess/.wts/context.md"
# The assertion that carries the rest: a worktree dirtied by .wts/ is one
# `wts gc` refuses to tear down and `wts ls` shows as dirty, forever, for every
# session that ever had a document.
check "the worktree stays clean" \
  eval '[[ -z "$(git -C "$WT/docsess" status --porcelain)" ]]'
check "the registry records the document" \
  eval '[[ "$(reg_field docsess docs)" == "[\"spec\"]" ]]'
WTS_NO_ATTACH=1 "$WTS" docsess smoke >/dev/null
check "an idempotent re-run does not detach it" \
  eval '[[ "$(reg_field docsess docs)" == "[\"spec\"]" ]]'

check "--doc=<slug> is accepted too" \
  env WTS_NO_ATTACH=1 "$WTS" docsess2 smoke --doc=spec
check "and attaches" test -s "$WT/docsess2/.wts/context.md"
"$WTS" rm docsess2 -f >/dev/null

fails_with "is a layout, not a document" env WTS_NO_ATTACH=1 "$WTS" amb smoke --doc smoke
refute "a layout given to --doc creates nothing" test -e "$WT/amb"
fails_with "not a document" env WTS_NO_ATTACH=1 "$WTS" amb smoke --doc nope
refute "an unknown document creates nothing" test -e "$WT/amb"

rm -rf "$WT/docsess/.wts"
"$WTS" stop docsess >/dev/null
"$WTS" restore docsess >/dev/null
check "restore rebuilds a context file that disappeared" test -s "$WT/docsess/.wts/context.md"

refute "--send refuses a session whose agent pane is unknown" \
  "$SWITCH" --send docsess "echo wts-doc-send-refused"
q "INSERT OR REPLACE INTO agent_panes (session, claude_session, pane, at) VALUES ('docsess', '', '$(tmux display-message -p -t "=docsess:" '#{pane_id}')', strftime('%s','now'))"
check "--send is the one sender into a pane" \
  "$SWITCH" --send docsess "echo wts-doc-send-ok"
check "the sent line lands" pane_shows docsess wts-doc-send-ok
"$WTS" doc use spec docsess >/dev/null
check "doc use reaches the session's pane" pane_contains docsess ".wts/context.md"

check "fzf accepts the ctrl-e binding" \
  eval 'printf "x\n" | fzf --bind="ctrl-e:execute(true)+refresh-preview" --filter=x'
check "the key table lists ^e" \
  eval 'out=$("$WTS" keys); [[ "$out" == *"^e"* && "$out" == *"context document"* ]]'

# The library picker, driven the way ctrl-e drives it: from a terminal, with its
# stdout captured. It was gated on -t 1, which no caller can satisfy -- they all
# read the slug from a command substitution -- so fzf never opened once and the
# numbered fallback took every call. The pane's PATH comes from a wrapper
# because tmux rebuilds it for a new pane.
cat > "$SANDBOX/bin/pick-probe" <<EOF
#!/bin/sh
export PATH="$PATH"
export XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME"
_=\$("$ROOT/libexec/wts/wts-doc" pick)
EOF
chmod +x "$SANDBOX/bin/pick-probe"
# A title of more than two words, to catch the other half of the bug: the rows
# are printf-padded columns and fzf splits on runs of whitespace, so the
# --with-nth=1,2,3 that used to be here showed the slug and the first two words
# of the title -- and never the kind or the age.
LONG="$SANDBOX/contract.md"
print -rl -- "# The idempotent webhook delivery contract" "" "One retry." > "$LONG"
"$WTS" doc add "$LONG" --name contract >/dev/null
tmux new-session -d -s pickprobe -x 100 -y 20 "$SANDBOX/bin/pick-probe"
check "the doc picker opens fzf on a terminal, not the numbered list" \
  pane_contains pickprobe "doc>"
check "the picker shows the whole title, not its first two words" \
  pane_contains pickprobe "The idempotent webhook delivery contract"
check "the picker shows the kind and age columns too" \
  pane_contains pickprobe "file"
tmux kill-session -t "=pickprobe" 2>/dev/null || true

# ctrl-e when no document is picked: esc, or enter on a filter that matches
# nothing. It used to hold a blank screen saying "press any key" -- the README
# demo's scene 6 for several releases -- because the pick happened inside
# `wts doc use ""`, which then exited 0 in silence. The probe says when the
# bind's command has returned.
cat > "$SANDBOX/bin/ctrl-e-probe" <<EOF
#!/bin/sh
export PATH="$PATH"
export XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME"
"$SWITCH" --doc docsess docsess
echo ctrl-e-probe-back
exec sleep 30
EOF
chmod +x "$SANDBOX/bin/ctrl-e-probe"
tmux new-session -d -s ctrleprobe -x 100 -y 20 "$SANDBOX/bin/ctrl-e-probe"
pane_contains ctrleprobe "doc>" || true
tmux send-keys -t "=ctrleprobe:" Escape
check "ctrl-e: esc in the picker goes straight back to the list" \
  pane_contains ctrleprobe ctrl-e-probe-back
refute "ctrl-e: and holds no empty 'press any key' screen" \
  pane_contains ctrleprobe "press any key"
tmux kill-session -t "=ctrleprobe" 2>/dev/null || true
tmux new-session -d -s ctrleprobe -x 100 -y 20 "$SANDBOX/bin/ctrl-e-probe"
pane_contains ctrleprobe "doc>" || true
tmux send-keys -t "=ctrleprobe:" zzqqx
# Apart: fzf filters asynchronously, and an enter typed with the filter would
# accept the first row before it is filtered out.
pane_contains ctrleprobe "0/" || true
tmux send-keys -t "=ctrleprobe:" Enter
check "ctrl-e: enter on a filter that matches nothing goes back too" \
  pane_contains ctrleprobe ctrl-e-probe-back
tmux kill-session -t "=ctrleprobe" 2>/dev/null || true
tmux new-session -d -s ctrleprobe -x 100 -y 20 "$SANDBOX/bin/ctrl-e-probe"
pane_contains ctrleprobe "doc>" || true
tmux send-keys -t "=ctrleprobe:" contra
# 1/2, not 1/: one match out of both rows. The picker's --sync is what makes
# this enough: without it fzf drew the prompt with one row read, matched the
# filter against that row alone, and the enter picked nothing (seen on CI).
pane_contains ctrleprobe "1/2" || true
tmux send-keys -t "=ctrleprobe:" Enter
check "ctrl-e: a document picked by its slug is attached, then a key is awaited" \
  eval 'pane_contains ctrleprobe "press any key" && [[ "$(reg_field docsess docs)" == *contract* ]]'
tmux kill-session -t "=ctrleprobe" 2>/dev/null || true
"$WTS" doc forget contract >/dev/null

"$WTS" rm docsess -f >/dev/null
refute "rm leaves no husk behind .wts/" test -d "$WT/docsess"
"$WTS" doc forget spec >/dev/null
refute "doc forget drops the cached body" doc_cached spec
refute "doc forget drops the library entry" \
  jq -e '.docs | has("spec")' "$XDG_CONFIG_HOME/wts/docs.json"
check "doc rm still forgets, for what was scripted before forget" "$WTS" doc rm ptr

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
refute "restore of a name no session has fails" "$WTS" restore zzqqx
"$WTS" restore auth-form >/dev/null
check "restore restarts a stopped session" has_session auth-form
check "restore of a running session is no failure" "$WTS" restore auth-form

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

# A branch made by hand, worked on and merged: gc's to take only when asked.
git -C "$REPO" switch -q -c develop
print dev > "$REPO/dev.txt"
git -C "$REPO" add dev.txt
git -C "$REPO" commit -qm dev
git -C "$REPO" switch -q main
git -C "$REPO" merge -q --ff-only develop

# The cost is said in the dry run, where it can still be declined.
check "the dry run says --apply will ask Claude for the retrospectives" eval '
  out=$(WTS_NO_LLM= "$WTS" gc --no-fetch); [[ "$out" == *"asks Claude for 1 retrospective(s)"*"--no-retro"* ]]'
refute "and not under --no-retro" eval '
  out=$(WTS_NO_LLM= "$WTS" gc --no-fetch --no-retro); [[ "$out" == *"asks Claude"* ]]'
# The model it names is the one --apply will call. Every case passes
# WTS_RETRO_MODEL, empty when it is the fallback under test: a ~/.zshenv that
# exports a default would otherwise decide the outcome on this machine only.
check "the dry run names the retrospectives' model" eval '
  out=$(WTS_NO_LLM= WTS_RETRO_MODEL=opus WTS_MODEL=haiku "$WTS" gc --no-fetch)
  [[ "$out" == *"one opus call each"* ]]'
check "and WTS_MODEL's when WTS_RETRO_MODEL is empty" eval '
  out=$(WTS_NO_LLM= WTS_RETRO_MODEL= WTS_MODEL=sonnet "$WTS" gc --no-fetch)
  [[ "$out" == *"one sonnet call each"* ]]'

"$WTS" gc --no-fetch --apply >/dev/null
check "gc leaves a merged branch no wts session had" git show-ref --verify --quiet refs/heads/develop
check "and says how many it did not look at" eval '
  out=$("$WTS" gc --no-fetch); [[ "$out" == *"not made by a wts session, not looked at: 1 "* ]]'
"$WTS" gc --no-fetch --all-branches --apply >/dev/null
refute "gc --all-branches takes it" git show-ref --verify --quiet refs/heads/develop
refute "gc tears down the merged session" has_session auth-form
refute "gc removes the merged worktree" test -d "$WT/auth-form"
refute "gc deletes the merged branch" git show-ref --verify --quiet refs/heads/feature/auth-form
refute "gc drops the registry entry" in_registry auth-form
check "gc spares a branch without commits" has_session export-users-csv
check "gc spares its worktree" test -d "$WT/export-users-csv"
check "gc spares sibling folders" test -f "$SANDBOX/code/demo-notes/todo.txt"

# A second repository: `wts ls` names the repository of each row once there are
# two, and `gc --all` collects both from anywhere.
REPO2="$SANDBOX/code/other"
mkdir -p "$REPO2"
git -C "$REPO2" init -q
print hi > "$REPO2/README"
git -C "$REPO2" add README
git -C "$REPO2" commit -qm init
refute "ls has no REPO column with one repository" eval '"$WTS" ls | head -1 | grep -q REPO'
refute "nor the switcher" eval '"$SWITCH" --list | sed -n 2p | grep -q REPO'
( cd "$REPO2" && env WTS_NO_ATTACH=1 "$WTS" elsewhere smoke >/dev/null )
check "ls adds a REPO column once sessions span two repositories" eval '
  out=$("$WTS" ls)
  [[ "${out%%$'\''\n'\''*}" == *REPO* && "$out" == *"elsewhere "*" other "* ]]'
check "the switcher adds a REPO column too, named after the repository" eval '
  l=$("$SWITCH" --list); [[ "$(print -r -- "$l" | sed -n 2p)" == "SESSION"*" REPO "* ]] \
    && print -r -- "$l" | grep -q "^elsewhere[*]\{0,1\}  *other " \
    && print -r -- "$l" | grep -q "^export-users-csv  *demo "'
check "in the skeleton as well, same layout" \
  eval 'diff <("$SWITCH" --list-fast | sed -n 2p) <("$SWITCH" --list | sed -n 2p)'
check "rows with a REPO column are padded to the list width" \
  eval 'WTS_SWITCH_COLS=70 "$SWITCH" --list | same_width 70 \
        && WTS_SWITCH_COLS=70 "$SWITCH" --list-fast | same_width 70'
check "gc --all collects every repository with a session, from outside any" eval '
  out=$(cd "$SANDBOX" && "$WTS" gc --all --no-fetch)
  [[ "$out" == *"Garbage collection — demo "* && "$out" == *"Garbage collection — other "* ]]'
check "and starts each from its main worktree, even from inside another" eval '
  out=$(cd "$WT/export-users-csv" && "$WTS" gc --all --no-fetch)
  [[ "$out" == *"Garbage collection — demo "* && "$out" != *"— export-users-csv "* ]]'
# The hook lists the sessions that can collide: another repository's cannot.
check "alone in its repository, an agent gets no directives and no sibling list" eval '
  out=$(cd "$SANDBOX/code/other-worktrees/elsewhere" && env -u TMUX -u TMUX_PANE "$ROOT/libexec/wts/wts-context")
  [[ "$out" == *"No other wts session works on this repository"* && "$out" != *export-users-csv* \
     && "$out" != *"db set"* ]]'
check "and the other repository does not list it" eval '
  out=$(cd "$WT/export-users-csv" && env -u TMUX -u TMUX_PANE "$ROOT/libexec/wts/wts-context")
  [[ "$out" != *elsewhere* ]]'
mkdir -p "$SANDBOX/code/other-worktrees/husk"
# A folder no wts session was named after is out of the default scope.
check "gc leaves a folder no session was named after, and says so" eval '
  out=$(cd "$SANDBOX" && "$WTS" gc --all --no-fetch)
  [[ "$out" != *"/other-worktrees/husk"* && "$out" == *"1 other folder(s) without .git"* ]]'
check "its dry run names --all in the command to run next" eval '
  out=$(cd "$SANDBOX" && "$WTS" gc --all --all-branches --no-fetch)
  [[ "$out" == *"/other-worktrees/husk"* && "$out" == *"Run again with: wts gc --all --apply"* ]]'
rmdir "$SANDBOX/code/other-worktrees/husk"
"$WTS" rm elsewhere -f >/dev/null

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

# ─── State database: wts db, notes, the Claude hook ──────────────────────────
# Every Claude session must be able to read the shared state and leave notes,
# concurrently, without being able to damage wts's own tables.

WTS_NO_ATTACH=1 "$WTS" dbsess smoke >/dev/null
WTS_NO_ATTACH=1 "$WTS" dbpeer "fix the peer's login" smoke >/dev/null
CONTEXT="$ROOT/libexec/wts/wts-context"

check "the database is in WAL mode" eval '[[ "$(q "PRAGMA journal_mode")" == wal ]]'
apostrophe_intact() { [[ "$(reg_field dbpeer prompt)" == "fix the peer's login" ]] }
check "a phrase with an apostrophe is stored intact" apostrophe_intact
check "db sql reads the registry" eval '"$WTS" db sql "SELECT name FROM sessions" | grep -qx dbsess'
check "db sql --json" \
  eval '"$WTS" db sql "SELECT count(*) AS n FROM sessions" --json | jq -e ".[0].n >= 2"'
refute "db sql cannot write" "$WTS" db sql "DELETE FROM sessions"
refute "db sql cannot read files" "$WTS" db sql "SELECT readfile('/etc/hosts')"
check "the registry survived the attempt" in_registry dbsess

db_tables_lists() {
  local out
  out=$("$WTS" db tables)
  [[ "$out" == *$'\n'sessions$'\t'<->$'\t'<->* ]]
}
check "db tables lists sessions with its counts" db_tables_lists
db_tables_json() {
  local out
  out=$("$WTS" db tables --json)
  print -r -- "$out" | jq -e '.[] | select(.table == "sessions") | .rows >= 2' >/dev/null
}
check "db tables --json parses" db_tables_json
db_schema_one() {
  local out
  out=$("$WTS" db schema sessions)
  [[ "$out" == *"CREATE TABLE sessions"* && "$out" != *"CREATE TABLE notes"* ]]
}
check "db schema <table> prints that table only" db_schema_one
refute "db schema on an unknown table fails" "$WTS" db schema no_such_table
DBSESS_ROWID=$(q "SELECT rowid FROM sessions WHERE name = 'dbsess'")
db_row_shows() {
  local out
  out=$("$WTS" db row sessions "$DBSESS_ROWID")
  [[ "$out" == *"name = dbsess"* ]]
}
check "db row prints one record, one field per line" db_row_shows
db_row_json() {
  local out
  out=$("$WTS" db row sessions "$DBSESS_ROWID" --json)
  [[ "$(print -r -- "$out" | jq -r '.[0].name')" == dbsess ]]
}
check "db row --json" db_row_json
refute "db row on an unknown table fails" "$WTS" db row no_such_table 1
refute "db row on a missing rowid fails" "$WTS" db row sessions 999999
refute "db row rejects a non-numeric rowid" "$WTS" db row sessions "1 OR 1=1"
db_browse_no_tty() {
  local out rc=0
  out=$("$WTS" db browse </dev/null 2>&1) || rc=$?
  (( rc == 2 )) && [[ "$out" == *"wts db tables"* ]]
}
check "db browse without a terminal exits 2 and names wts db tables" db_browse_no_tty
refute "db set outside any session fails" eval '(cd / && "$WTS" db set k v)'
# `wts db` is a verb an agent runs without a prompt, and --session let it
# rewrite or delete the notes of any other session. Without a terminal, a note
# is written from its own session only; usage errors exit 2, as the skill says.
check "db set as another session without a terminal: exit 2, nothing written" eval '
  (cd "$WT/dbsess" && "$WTS" db set k v --session dbpeer </dev/null 2>/dev/null); (( $? == 2 )) \
  && [[ -z "$(q "SELECT 1 FROM notes WHERE session = '\''dbpeer'\'' AND key = '\''k'\''")" ]]'
check "nor from outside any session" eval '
  (cd / && "$WTS" db set k v --session dbpeer </dev/null 2>/dev/null); (( $? == 2 ))'
check "--session naming the caller itself still writes" eval '
  (cd "$WT/dbsess" && "$WTS" db set own v --session dbsess </dev/null 2>/dev/null) \
  && [[ "$(q "SELECT value FROM notes WHERE session = '\''dbsess'\'' AND key = '\''own'\''")" == v ]]'
check "db del as another session is refused the same way" eval '
  (cd "$WT/dbpeer" && "$WTS" db del own --session dbsess </dev/null 2>/dev/null); (( $? == 2 )) \
  && [[ -n "$(q "SELECT 1 FROM notes WHERE session = '\''dbsess'\'' AND key = '\''own'\''")" ]]'
check "reading another session's note is not a write" eval '
  [[ "$(cd "$WT/dbpeer" && "$WTS" db get own --session dbsess </dev/null)" == v ]]'
(cd "$WT/dbsess" && "$WTS" db del own >/dev/null 2>&1) || true
check "a db usage error exits 2" eval '"$WTS" db set lonely </dev/null 2>/dev/null; (( $? == 2 ))'
check "so does an unknown db command" eval '"$WTS" db frobnicate </dev/null 2>/dev/null; (( $? == 2 ))'

note_from_worktree() {
  (cd "$WT/dbsess" && "$WTS" db set api "it's 429 on /login") &&
    [[ "$(q "SELECT session || '|' || value FROM notes WHERE key = 'api'")" == "dbsess|it's 429 on /login" ]]
}
check "db set finds the session from the worktree" note_from_worktree
get_back() { [[ "$(cd "$WT/dbsess" && "$WTS" db get api)" == "it's 429 on /login" ]] }
check "db get reads it back" get_back

# From a pane, outside the worktree: the session comes from $TMUX_PANE.
note_from_pane() {
  local i
  tmux send-keys -t "=dbpeer:" "cd / && $WTS db set from-pane yes" Enter
  for i in {1..50}; do
    [[ "$(q "SELECT session FROM notes WHERE key = 'from-pane'")" == dbpeer ]] && return 0
    sleep 0.1
  done
  return 1
}
check "db set finds the session from the tmux pane" note_from_pane

# Ten agents and three registry writers at once: nothing lost, nothing locked.
concurrent_writes() {
  local i errs="$SANDBOX/db-errs"
  : > "$errs"
  for i in {1..10}; do
    (cd "$WT/dbsess" && "$WTS" db set "k$i" "v$i" 2>>"$errs") &
  done
  for i in {1..3}; do
    WTS_NO_ATTACH=1 "$WTS" dbsess smoke >/dev/null 2>>"$errs" &
  done
  wait
  [[ "$(q "SELECT count(*) FROM notes WHERE session = 'dbsess' AND key GLOB 'k*'")" == 10 ]] &&
    ! grep -q -i -e locked -e "registry not updated" "$errs"
}
check "concurrent writers lose nothing" concurrent_writes
check "notes --all lists every session's notes" \
  eval '"$WTS" db notes --all --json | jq -e "map(.session) | unique == [\"dbpeer\", \"dbsess\"]"'

# The SessionStart hook.
check "the hook is silent outside a wts session" \
  eval '[[ -z "$(cd / && env -u TMUX -u TMUX_PANE "$CONTEXT")" ]]'
hook_in_session() {
  local out
  out=$(cd "$WT/dbsess" && env -u TMUX -u TMUX_PANE "$CONTEXT")
  [[ "$out" == *'session `dbsess`'* && "$out" == *"- dbpeer (feature/dbpeer): fix the peer's login"* \
     && "$out" == *"dbpeer/from-pane"* && "$out" == *"db set <key>"* \
     && "$out" != *"dbsess/api"* ]]
}
check "the hook describes the other sessions and their notes" hook_in_session
check "it dates their brief" eval '
  q "INSERT OR REPLACE INTO briefs VALUES ('\''dbpeer'\'', '\''k'\'', '\''done: login fixed'\'', strftime('\''%s'\'', '\''now'\'') - 7200)"
  out=$(cd "$WT/dbsess" && env -u TMUX -u TMUX_PANE "$CONTEXT")
  q "DELETE FROM briefs WHERE session = '\''dbpeer'\''"
  [[ "$out" == *"brief, 2h ago: done: login fixed"* ]]'

# Claude Code's messages between sessions: each sibling line names the agent to
# SendMessage, as Claude Code's session file lists it, and only when messages
# work here (claude_messaging: the version and crossSessionInbound, cached in kv).
msg_reset() { q "DELETE FROM kv WHERE key = 'claude.messaging'" }
peer_file() { # <name> <pid>
  jq -n --arg c "$WT/dbpeer" --arg n "$1" --argjson p "$2" \
    '{pid: $p, sessionId: "peer-1", cwd: $c, name: $n, kind: "interactive", peerProtocol: 1, startedAt: 1}' \
    > "$CLAUDE_CONFIG_DIR/sessions/77777.json"
}
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
peer_file dbpeer $$
msg_ctx() { (cd "$WT/dbsess" && env -u TMUX -u TMUX_PANE "$CONTEXT") }
msg_old_claude() {
  local out
  msg_reset; out=$(msg_ctx)
  [[ "$out" == *"- dbpeer (feature/dbpeer): fix the peer's login"* && "$out" != *SendMessage* ]]
}
check "an older claude: no SendMessage in the context" msg_old_claude
check "and doctor says which version it needs" eval '
  out=$("$WTS" doctor); [[ "$out" == *"messages between sessions: needs claude >= 2.1.224 (this is 0.0.0)"* ]]'
export WTS_SMOKE_CLAUDE_VERSION=2.1.300
msg_reach() { # <name>
  local out
  msg_reset; out=$(msg_ctx)
  [[ "$out" == *"- dbpeer (feature/dbpeer): fix the peer's login — reach \`$1\` with SendMessage"* ]]
}
check "a recent one: the sibling line says the name to reach it by" msg_reach dbpeer
check "the verdict is cached in kv, keyed by the binary" eval '
  [[ "$(q "SELECT value FROM kv WHERE key = '\''claude.messaging'\''")" == "$SANDBOX/bin/claude:"*"|available" ]]'
check "doctor: available" eval '
  out=$("$WTS" doctor); [[ "$out" == *"✓ messages between sessions: available"* ]]'
# A layout without --name: Claude Code derives one, and a prefix is refused.
peer_file dbpeer-3c $$
check "the name is the one Claude Code lists, not the session's" msg_reach dbpeer-3c
# Claude Code leaves a crashed agent's file behind.
( : ) & dead=$!; wait $dead
peer_file dbpeer $dead
refute "an agent whose process is gone gets no name" msg_reach dbpeer
peer_file dbpeer $$
print -r -- '{"crossSessionInbound": "refuse"}' > "$CLAUDE_CONFIG_DIR/settings.json"
refute "crossSessionInbound refuse: no SendMessage" msg_reach dbpeer
check "and doctor names the setting and the file" eval '
  msg_reset; out=$("$WTS" doctor)
  [[ "$out" == *"⚠ messages between sessions: refused by crossSessionInbound in $CLAUDE_CONFIG_DIR/settings.json"* ]]'
print -r -- '{"crossSessionInbound": "hold"}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "hold: doctor says each message waits for approval" eval '
  msg_reset; out=$("$WTS" doctor); [[ "$out" == *"held by crossSessionInbound"*"waits for your approval"* ]]'
# A repository may tighten the setting: read on every call, not cached.
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
mkdir -p "$WT/dbsess/.claude"
print -r -- '{"crossSessionInbound": "refuse"}' > "$WT/dbsess/.claude/settings.local.json"
refute "a worktree's own settings can refuse" msg_reach dbpeer
rm -rf "$WT/dbsess/.claude"
check "and without them it is said again" msg_reach dbpeer
rm -f "$CLAUDE_CONFIG_DIR/sessions/77777.json"
unset WTS_SMOKE_CLAUDE_VERSION
msg_reset

settings="$CLAUDE_CONFIG_DIR/settings.json"
print -r -- '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$settings"
check "setup claude prints the hook" eval '"$WTS" setup claude | grep -qF "$ROOT/libexec/wts/wts-context"'
"$WTS" setup claude --install >/dev/null
"$WTS" setup claude --install >/dev/null
check "setup claude --install is idempotent" \
  jq -e '[.hooks.SessionStart[].hooks[] | select(.command | endswith("/wts-context"))] | length == 1' "$settings"
check "setup claude --install keeps the other hooks" \
  jq -e '[.hooks.SessionStart[].hooks[] | select(.command == "echo mine")] | length == 1' "$settings"
# The hook tells the agent to run `wts db …`: without the allow rule the first
# thing every agent did was wait, blocked, on a permission prompt for it.
check "setup claude prints the permissions the hook needs" \
  eval '"$WTS" setup claude | grep -qF "Bash(wts db:*)"'
check "setup claude --install allows them, once" \
  jq -e '[.permissions.allow[] | select(. == "Bash(wts db:*)")] | length == 1' "$settings"
check "setup claude prints the four event hooks" eval '
  out=$("$WTS" setup claude)
  [[ "$out" == *"wts-hook prompt"* && "$out" == *"wts-hook stop"* \
  && "$out" == *"wts-hook notification"* && "$out" == *"wts-hook end"* ]]'
check "setup claude --install adds each event hook once" \
  jq -e '[ .hooks.UserPromptSubmit[].hooks[], .hooks.Stop[].hooks[],
           .hooks.Notification[].hooks[], .hooks.SessionEnd[].hooks[]
         | select(.command | test("/wts-hook ")) ] | length == 4' "$settings"
check "setup claude prints the start hook next to wts-context" eval '
  out=$("$WTS" setup claude); [[ "$out" == *"wts-context\", \"timeout\": 5 },"*"wts-hook start"* ]]'
check "setup claude --install puts it on SessionStart, once, next to the user's own" \
  jq -e '([.hooks.SessionStart[].hooks[] | select(.command | endswith("/wts-hook start"))] | length == 1)
         and ([.hooks.SessionStart[].hooks[] | select(.command == "echo mine")] | length == 1)' "$settings"
check "setup tmux adds the status line segment" \
  eval 'out=$("$WTS" setup tmux); [[ "$out" == *"wts-status --line"* ]]'

# --install: one block, between markers, whatever was there. A block from before
# the markers is replaced; a status line the user moved below a theme is kept
# where it is and not added a second time.
TH="$SANDBOX/home"
mkdir -p "$TH"
cat > "$TH/.tmux.conf" <<'EOF'
set -g mouse on

# ─── wts (generated by `wts setup tmux`, wts 0.1.1) ───────────────────
bind s display-popup -E -w 85% -h 70% "/old/libexec/wts/wts-switch"
bind a run-shell "/old/libexec/wts/wts-switch --next"

set -g status-right "theme"
set -ag status-right " #(/old/libexec/wts/wts-status --line)"
EOF
HOME="$TH" "$WTS" setup tmux --install >/dev/null
HOME="$TH" "$WTS" setup tmux --install >/dev/null
check "setup tmux --install replaces a block from before the markers" eval '
  c=$(<"$TH/.tmux.conf")
  [[ "$c" != *"wts 0.1.1"* && "$c" != *"/old/libexec/wts/wts-switch"* \
     && "$c" == *"$ROOT/libexec/wts/wts-switch"* && "$c" == *"set -g mouse on"* ]]'
check "and run twice, it keeps one block" eval '[[ $(grep -c "^# >>> wts " "$TH/.tmux.conf") == 1 ]]'
check "a status line moved out of the block is kept, not doubled" eval '
  [[ $(grep -c "wts-status --line" "$TH/.tmux.conf") == 1 ]] \
  && grep -qF "#(/old/libexec/wts/wts-status --line)" "$TH/.tmux.conf"'
check "a fresh tmux.conf gets the block, status line included" eval '
  H2="$SANDBOX/home2"; mkdir -p "$H2"
  HOME="$H2" "$WTS" setup tmux --install >/dev/null
  grep -q "^# <<< wts <<<" "$H2/.tmux.conf" && grep -qF "wts-status --line" "$H2/.tmux.conf"'

# wts doctor: everything the sandbox has, and a failure when a requirement is
# not there. Read-only: the database is not created by it.
check "doctor passes with what the test itself needs" eval '
  out=$("$WTS" doctor)
  [[ "$out" == *"✓ tmuxinator"* && "$out" == *"Integration"* && "$out" == *"→ ready"* ]]'
check "doctor names a missing requirement and fails" eval '
  out=$(env PATH="$nomux" "$WTS" doctor); (( $? == 1 )) && [[ "$out" == *"✗ tmuxinator not found"* ]]'
check "doctor runs tmuxinator, and fails on one that does not run" eval '
  out=$(env PATH="$badmux:$PATH" "$WTS" doctor); (( $? == 1 )) \
  && [[ "$out" == *"✗ tmuxinator is on PATH but does not run (exit 126)"* ]]'
check "doctor sees a tmux snippet from an older wts" eval '
  cp "$TH/.tmux.conf" "$TH/conf.keep"
  sed -i.x "s/^# >>> wts [^ ]* >>>/# >>> wts 0.9.0 >>>/" "$TH/.tmux.conf"
  out=$(HOME="$TH" "$WTS" doctor); mv "$TH/conf.keep" "$TH/.tmux.conf"
  [[ "$out" == *"tmux snippet: from wts 0.9.0"* ]]'

"$WTS" rm dbsess -f >/dev/null
no_notes_left() { [[ "$(q "SELECT count(*) FROM notes WHERE session = 'dbsess'")" == 0 ]] }
check "rm drops the session's notes" no_notes_left
"$WTS" rm dbpeer -f >/dev/null

# ─── Import of the pre-1.0 state files ───────────────────────────────────────

OLD="$SANDBOX/state-old"
mkdir -p "$OLD/wts/brief" "$OLD/wts/panehash"
print -r -- stale > "$OLD/wts/brief/legacy"
cat > "$OLD/wts/sessions.json" <<'EOF'
{
  "legacy": {"profile": "smoke", "repo_root": "/r", "worktree": "/w", "branch": "feature/legacy",
             "subdir": "", "context": "", "prompt": "line one\nit's two", "docs": ["spec"],
             "created_at": "2026-01-01T00:00:00Z"},
  "bare": {"worktree": "/w2"}
}
EOF
import_runs() {
  local err
  err=$(XDG_STATE_HOME="$OLD" "$WTS" db path 2>&1 >/dev/null)
  [[ "$err" == *"state imported"*"2 sessions"* ]]
}
check "the first command imports sessions.json" import_runs
qo() { sqlite3 -init /dev/null "$OLD/wts/wts.db" "$@" }
check "the old file is kept, renamed" test -s "$OLD/wts/sessions.json.migrated"
refute "the old file is gone" test -e "$OLD/wts/sessions.json"
refute "the old caches are gone" test -e "$OLD/wts/brief"
prompt_survives() {
  [[ "$(qo "SELECT prompt FROM sessions WHERE name = 'legacy'")" == "line one"$'\n'"it's two" ]]
}
check "a multiline prompt with an apostrophe survives the import" prompt_survives
bare_defaults() { [[ "$(qo "SELECT docs || created_at FROM sessions WHERE name = 'bare'")" == '[]2'* ]] }
check "a sparse entry gets defaults" bare_defaults
# registry_json gained `task` and `task_title` when the task layer landed, so the
# output is compared on the keys the pre-1.0 file had: the promise to the jq
# readers is that none of those may change value or disappear, not that nothing
# may ever be added beside them.
same_shape() {
  local old="$OLD/wts/sessions.json.migrated" keys
  keys=$(jq -c '.legacy | keys' "$old") || return 1
  diff <(jq -S .legacy "$old") \
       <(XDG_STATE_HOME="$OLD" zsh -c 'source "$1/libexec/wts/wts-db.zsh"; registry_json' _ "$ROOT" \
         | jq -S --argjson k "$keys" '.legacy | with_entries(select(.key | IN($k[])))')
}
check "every pre-1.0 registry key reads back unchanged" same_shape
check "a second run imports nothing more" \
  eval '[[ -z "$(XDG_STATE_HOME="$OLD" "$WTS" db path 2>&1 >/dev/null)" ]]'

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

# The branch is origin/main itself, so every counter is zero. Against the local
# base it used to report ahead=1 and added=1.
check "delta measured against origin/<base>" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\")
        | .ahead == 0 and .behind == 0 and .added == 0 and .removed == 0"'
# An ancestor of the base, but only because nothing was committed yet: it used
# to read merged, and a switcher that sorts merged last and offers ctrl-d on
# them must not say so of a session created a second ago.
check "a branch with no commit yet is not merged" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\") | .merged == false"'
# Pins the contract: wts-brief reads .base and derives "origin/$base" itself, so
# it must stay the short name.
check "base still reports the short name" \
  eval '"$WTS" status --json | jq -e ".[] | select(.name == \"fresh-cut\") | .base == \"main\""'

# ─── gc: a fetch that fails says why ─────────────────────────────────────────
# `wts gc` used to run its fetch with 2>/dev/null, so "fetch failed" was all any
# broken fetch ever said — and a fetch it cannot prune is the one failure that
# makes gc find nothing at all (an aborted transaction leaves origin/<base>
# behind too). Both checks need the remote added just above.

git -C "$REPO" remote set-url origin "$SANDBOX/code/gone.git"
check "gc prints git's own error" eval '
  out=$("$WTS" gc 2>/dev/null)
  [[ "$out" == *"fetch --prune FAILED"* && "$out" == *"does not appear to be a git repository"* ]]'
check "a network failure names no colliding ref" eval '
  out=$("$WTS" gc 2>/dev/null)
  [[ "$out" != *"differ only by case"* ]]'
git -C "$REPO" remote set-url origin "$ORIGIN"

# Two refs differing only by case are ONE path on a case-insensitive filesystem,
# which is most macOS checkouts: the prune can neither lock them separately nor
# match their old values, so its single transaction aborts and takes the fetch
# with it. Reproduced exactly as a real repository gets there: pack the first ref
# away, after which nothing on disk stops the second spelling from being created.
if print -n '' > "$SANDBOX/A" && [[ -e "$SANDBOX/a" ]]; then
  rm -f "$SANDBOX/A"
  sha=$(git -C "$REPO" rev-parse main)
  other=$(git -C "$REPO" rev-parse main^)
  git -C "$REPO" update-ref refs/remotes/origin/zz/gone "$sha"
  git -C "$REPO" pack-refs --all
  git -C "$REPO" update-ref refs/remotes/origin/ZZ/gone "$other"
  check "gc names the refs colliding by case" eval '
    out=$("$WTS" gc 2>/dev/null)
    [[ "$out" == *"differ only by case"* \
    && "$out" == *"refs/remotes/origin/zz/gone"* \
    && "$out" == *"refs/remotes/origin/ZZ/gone"* \
    && "$out" == *"update-ref -d"* ]]'
  # One deletion per command: the two of them in a single transaction is the
  # collision itself, and the repair gc prints has to work.
  git -C "$REPO" update-ref -d refs/remotes/origin/ZZ/gone
  git -C "$REPO" update-ref -d refs/remotes/origin/zz/gone
  check "gc is happy again once they are gone" eval '
    out=$("$WTS" gc)
    [[ "$out" == *"fetch --prune ok"* ]]'
else
  rm -f "$SANDBOX/A"
  ok "case collision skipped (case-sensitive filesystem)"
fi

# ─── Capture: archive, retro, log, tasks ─────────────────────────────────────
# The point of the feature is that teardown stops destroying the evidence, so
# the checks are about what survives a `wts rm`, not about what it prints.

# A fresh state directory used to abort the very first command: db_init's
# trailing rmdir returns 1 on a directory that never existed, and bin/wts runs
# under set -e. It created the schema and then exited without printing anything.
check "a first-ever command in a fresh state directory works" eval '
  out=$(env XDG_STATE_HOME="$SANDBOX/fresh-state" "$WTS" ls 2>&1)
  [[ "$out" == *"No registered session"* ]]'

cd "$REPO"
env WTS_NO_ATTACH=1 "$WTS" archsess smoke "keep this" >/dev/null
"$WTS" rm archsess -f >/dev/null

check "wts rm archives the session" eval '[[ "$(q "select count(*) from archive where session = '\''archsess'\''")" == 1 ]]'
check "and still removes it from the registry" eval '[[ "$(q "select count(*) from sessions where name = '\''archsess'\''")" == 0 ]]'
check "the archive keeps the context the registry held" eval '
  [[ "$(q "select context from archive where session = '\''archsess'\''")" == "keep this" ]]'
check "rm -f records the work as abandoned" eval '
  [[ "$(q "select outcome from archive where session = '\''archsess'\''")" == abandoned ]]'
check "no retrospective is written by rm" eval '
  [[ -z "$(q "select retro_delivered from archive where session = '\''archsess'\''")" ]]'

env WTS_NO_ATTACH=1 "$WTS" noarch smoke >/dev/null
env WTS_NO_ARCHIVE=1 "$WTS" rm noarch -f >/dev/null
check "WTS_NO_ARCHIVE keeps the capture out" eval '
  [[ "$(q "select count(*) from archive where session = '\''noarch'\''")" == 0 ]]'

# The retrospective, against the same stand-in as naming (stub_claude): the
# "label: value" lines its body prints are the fields of the JSON answer.
RSTUBS="$SANDBOX/retro-stubs"
retro_with() { # <sh-body> [env=value...] — wts retro against that stand-in
  stub_claude "$RSTUBS" "$1"; shift
  env PATH="$RSTUBS:$PATH" WTS_NO_LLM= "$@" "$WTS" retro --force archsess 2>&1
}
archsess_usage() { # the wts:retro row of archsess's archived incarnation
  q "SELECT u.messages || '|' || u.cost_usd FROM usage u JOIN archive a
       ON a.session = u.session AND a.created_at = u.created_at
     WHERE a.session = 'archsess' AND u.transcript = 'wts:retro'"
}

check "a four-field answer is stored field by field" eval '
  retro_with "printf \"delivered: the bucket shipped\nresisted: a flaky spec\nresolved: pinned the clock\nabandoned: -\n\"" >/dev/null
  [[ "$(q "select retro_delivered from archive where session = '\''archsess'\''")" == "the bucket shipped" \
  && "$(q "select retro_resisted from archive where session = '\''archsess'\''")" == "a flaky spec" \
  && "$(q "select retro_resolved from archive where session = '\''archsess'\''")" == "pinned the clock" ]]'
check "the retro is asked as JSON, against its four fields" eval '
  retro_with "printf \"%s\n\" \"\$*\" > \"$RSTUBS/args\"; printf \"delivered: x\n\"" >/dev/null
  args=$(<"$RSTUBS/args")
  [[ "$args" == *"--output-format json"* && "$args" == *"--json-schema"*"\"abandoned\""* ]]'
check "its cost goes to the archived incarnation" eval '
  [[ "$(archsess_usage)" == 2\|0.0008 ]]'
# The retrospective's list of the author's messages leaves out what another
# session sent: its record opens with "Another Claude session sent a message",
# which the old filter (a leading "<") let through. After the cost check above,
# which counts the calls before it.
retro_facts_skip_peers() {
  local tr="$SANDBOX/retro-msg.jsonl" facts="$SANDBOX/retro-facts"
  print -r -- '{"type":"user","message":{"content":"first: build the bucket"}}
{"type":"user","isMeta":true,"turnOrigin":"peer","origin":{"kind":"peer","name":"rate-limit"},"message":{"content":"Another Claude session sent a message:\nSIBLING-WORDS"}}
{"type":"user","isMeta":true,"turnOrigin":"system","message":{"content":"[Cross-session idle notice] NOTICE-WORDS"}}
{"type":"user","message":{"content":"AUTHOR-SECOND use the clock"}}' > "$tr"
  q "UPDATE archive SET transcript = '$tr' WHERE session = 'archsess'"
  retro_with "cat > $facts; printf 'delivered: x\n'" >/dev/null
  q "UPDATE archive SET transcript = '' WHERE session = 'archsess'"
  [[ "$(<$facts)" == *"AUTHOR-SECOND"* && "$(<$facts)" == *"2 message(s) from the author"* \
     && "$(<$facts)" != *SIBLING-WORDS* && "$(<$facts)" != *NOTICE-WORDS* ]]
}
check "the retrospective's facts leave out a sibling's messages" retro_facts_skip_peers
# The prose of a model that ignored the schema, which the regex used to fish
# for: no structured_output, so nothing is stored but the reason.
check "an answer without its fields is an error, not a retro" eval '
  retro_with "echo '"'"'{\"type\":\"result\",\"is_error\":true,\"result\":\"There is an issue with the selected model (x).\"}'"'"'; exit 1" >/dev/null
  [[ "$(q "select retro_error from archive where session = '\''archsess'\''")" == *"selected model (x)"* ]]'
# A transcript is deleted within 30 days, so a partial answer is worth more than
# an error whose evidence is gone: the opposite rule from wts-brief.
check "a partial answer is kept, not rejected" eval '
  retro_with "printf \"delivered: only this line\n\"" >/dev/null
  [[ "$(q "select retro_delivered from archive where session = '\''archsess'\''")" == "only this line" \
  && "$(q "select retro_resisted from archive where session = '\''archsess'\''")" == unknown ]]'
check "a failing claude records why, and counts nothing" eval '
  out=$(retro_with "echo boom >&2; exit 1")
  [[ "$out" == *"0 of 1"* \
  && "$(q "select retro_error from archive where session = '\''archsess'\''")" == *boom* ]]'
check "a timeout says how long it waited" eval '
  retro_with "sleep 3" WTS_RETRO_TIMEOUT=1 >/dev/null
  [[ "$(q "select retro_error from archive where session = '\''archsess'\''")" == *"no answer in 1s"* ]]'
# Haiku's thinking is what took the retros of long sessions past 60 s (4,500
# tokens of it before four lines), not the size of their facts: the call turns
# it off, and a transcript of thousands of records still yields bounded facts.
retro_with "printf '%s\n' \"\$*\" > '$RSTUBS/args'; printf 'delivered: x\n'" >/dev/null
check "the retro asks with thinking off" eval '
  grep -qF "\"alwaysThinkingEnabled\":false" "$RSTUBS/args"'
# Its own model, so that a stronger one writes the retrospectives without
# slowing naming or wts brief. WTS_RETRO_MODEL is always passed, empty for the
# fallbacks: ~/.zshenv may export it, and every wts script reads it again.
retro_model_of() { # [env=value...] — the --model the retro passed to claude
  retro_with "printf '%s\n' \"\$*\" > '$RSTUBS/args'; printf 'delivered: x\n'" "$@" >/dev/null
  local w=(${=$(<"$RSTUBS/args")}) i
  for (( i = 1; i < $#w; i++ )); do
    [[ "${w[i]}" == --model ]] && { print -r -- "${w[i+1]}"; return 0 }
  done
}
check "the retro uses WTS_RETRO_MODEL" eval '
  [[ "$(retro_model_of WTS_RETRO_MODEL=opus WTS_MODEL=)" == opus ]]'
check "and WTS_MODEL when WTS_RETRO_MODEL is empty" eval '
  [[ "$(retro_model_of WTS_RETRO_MODEL= WTS_MODEL=sonnet)" == sonnet ]]'
check "and haiku with neither" eval '
  [[ "$(retro_model_of WTS_RETRO_MODEL= WTS_MODEL=)" == haiku ]]'
check "WTS_RETRO_MODEL wins over WTS_MODEL" eval '
  [[ "$(retro_model_of WTS_RETRO_MODEL=opus WTS_MODEL=sonnet)" == opus ]]'
long_tr="$SANDBOX/long-transcript.jsonl"
big=$(printf "%04000d" 0)
for i in {1..1500}; do
  print -r -- '{"type":"user","message":{"content":"correction number '$i': '"${big[1,300]}"'"},"timestamp":"2026-10-03T10:00:00Z"}'
  print -r -- '{"type":"user","message":{"content":[{"type":"tool_result","content":"'"$big"'"}]}}'
  print -r -- '{"type":"assistant","message":{"content":[{"type":"text","text":"answer '$i' '"${big[1,500]}"'"}]}}'
done > "$long_tr"
old_tr=$(q "select transcript from archive where session = 'archsess'")
q "UPDATE archive SET transcript = '$long_tr' WHERE session = 'archsess'"
stub_claude "$RSTUBS" "wc -c > '$RSTUBS/facts-bytes'
printf 'delivered: long\n'"
env PATH="$RSTUBS:$PATH" WTS_NO_LLM= "$WTS" retro --force archsess >/dev/null 2>&1
check "a transcript of several MB gives at most 20 KB of facts" eval '
  (( $(wc -c < "$long_tr") > 5000000 && $(tr -d " " < "$RSTUBS/facts-bytes") <= 20000 )) \
  && [[ "$(q "select retro_delivered from archive where session = '\''archsess'\''")" == long ]]'
q "UPDATE archive SET transcript = '$old_tr' WHERE session = 'archsess'"
check "without a model the facts stay archived and it says so" eval '
  out=$("$WTS" retro --force archsess 2>&1)
  [[ "$out" == *"no model available"* && "$out" == *"facts are archived"* ]]'

# `wts log` is a public contract: version, the resolved window, and one work
# array whatever the sources.
check "wts log emits a versioned document" eval '
  "$WTS" log --no-things | jq -e ".version == 1 and (.work | type) == \"array\"" >/dev/null'
check "the window accepts an ISO date and a sqlite modifier" eval '
  "$WTS" log --no-things --since 2020-01-01 | jq -e ".range.since | startswith(\"2020-01-01\")" >/dev/null
  "$WTS" log --no-things --since "-1 days" | jq -e ".range.since != \"\"" >/dev/null'
check "an unreadable window is refused rather than guessed" \
  fails_with "cannot read --since" "$WTS" log --since "not a date"
check "the archived session is one work item with one session" eval '
  "$WTS" log --no-things --since 2020-01-01 \
    | jq -e "[.work[] | select(.sessions[]?.name == \"archsess\")] | length == 1" >/dev/null'
check "--brief drops the bulk and keeps the retrospective" eval '
  "$WTS" log --no-things --since 2020-01-01 --brief \
    | jq -e "[.work[].sessions[]] | all(.commits == [] and .notes == {})" >/dev/null'
check "without Things the corpus says so and keeps the wts half" eval '
  "$WTS" log --no-things --since 2020-01-01 \
    | jq -e ".sources.things.available == false and .sources.things.reason != \"\" and (.work | length) > 0" >/dev/null'
check "WTS_NO_THINGS is reported as the reason" eval '
  env WTS_NO_THINGS=1 "$WTS" log --since 2020-01-01 \
    | jq -e ".sources.things.reason | test(\"WTS_NO_THINGS\")" >/dev/null'

# `available`: the question the switcher and the footer ask, answered from the
# cached verdict alone. Reading Things itself is privileged on macOS ("iTerm
# would like to access data from other apps"), so no test here may probe for
# real either — the rows are seeded by hand, exactly as a real probe leaves them.
THINGSBIN="$ROOT/libexec/wts/wts-things"
q "delete from kv where key = 'things.db'"
check "never probed: no for the footer, yes for the key that will find out" eval '
  ! "$THINGSBIN" available && "$THINGSBIN" available --maybe'
q "insert or replace into kv values ('things.db', '')"
check "a probe that failed is a no for both: denied once, never asked again" eval '
  ! "$THINGSBIN" available && ! "$THINGSBIN" available --maybe'
q "insert or replace into kv values ('things.db', '/nowhere/main.sqlite')"
check "a probe that succeeded is a yes, without looking at the path again" eval '
  "$THINGSBIN" available && "$THINGSBIN" available --maybe'
check "WTS_NO_THINGS overrides the cache" eval '
  ! env WTS_NO_THINGS=1 "$THINGSBIN" available --maybe'
q "delete from kv where key = 'things.db'"

# The task layer. A local task, because the sandbox has no Things.
TASK=$(env WTS_NO_THINGS=1 "$WTS" task new "Ship the audit trail")
check "wts task new prints a local id" eval '[[ "$TASK" == local:* ]]'
env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tsess smoke --task "$TASK" >/dev/null
check "--task links the session it created" eval '
  [[ "$(q "select task from task_links where session = '\''tsess'\''")" == "$TASK" ]]'
# The highest-value half of the task layer: the URLs the author keeps in the task
# become context documents, as pointers rather than fetches — a task carries one
# to three links and paying a sonnet fetch each at creation would put minutes in
# front of a starting agent.
check "a task's links become context documents" eval '
  q "update tasks set links = json('"'"'[{\"url\":\"https://notion.test/cbs\",\"host\":\"notion.test\",\"kind\":\"notion\"}]'"'"') where id = \"$TASK\"" >/dev/null
  env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" docfromtask smoke --task "$TASK" >/dev/null
  grep -qF "https://notion.test/cbs" "$WT/docfromtask/.wts/context.md"'
check "and they are recorded as pointers, not failed fetches" eval '
  grep -qF "kind: pointer" "$WT/docfromtask/.wts/context.md"'
# The slug comes from the URL path, not the host, so the assertion is on the list
# being filled at all: that is what makes `wts restore` and `wts doc sync` see them.
check "the session records them in its own document list" eval '
  [[ "$(q "select json_array_length(docs) from sessions where name = '"'"'docfromtask'"'"'")" -ge 1 ]]'
"$WTS" rm docfromtask -f >/dev/null

check "the session carries the marker in ls" eval '
  out=$("$WTS" ls); [[ "$out" == *$'\''\n'\''"tsess "*"@ "* ]]'
check "status --json exposes task and task_title" eval '
  "$WTS" status --json --no-git tsess \
    | jq -e ".[0].task == \"$TASK\" and .[0].task_title == \"Ship the audit trail\"" >/dev/null'
# The one mistake --task can make, and it must name it rather than create a
# worktree whose task is a layout.
check "--task followed by a layout is named, and creates nothing" eval '
  out=$(env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tbad --task smoke 2>&1) && false
  [[ "$out" == *"is a layout, not a task"* ]] && [[ ! -e "$WT/tbad" ]]'
check "a second session can serve the same task" eval '
  env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tsess2 smoke >/dev/null
  env WTS_NO_THINGS=1 "$WTS" task link "$TASK" tsess2 >/dev/null
  [[ "$(q "select count(*) from task_links where task = '\''$TASK'\''")" == 2 ]]'
check "wts task ls groups them under the task" eval '
  out=$(env WTS_NO_THINGS=1 "$WTS" task ls)
  [[ "$out" == *"Ship the audit trail"* && "$out" == *tsess* && "$out" == *tsess2* ]]'
check "the task survives teardown, in the archive row" eval '
  "$WTS" rm tsess -f >/dev/null
  [[ "$(q "select task from archive where session = '\''tsess'\''")" == "$TASK" ]]'
check "and the live link went with the session" eval '
  [[ "$(q "select count(*) from task_links where session = '\''tsess'\''")" == 0 ]]'
check "unlink detaches without removing the session" eval '
  env WTS_NO_THINGS=1 "$WTS" task unlink tsess2 >/dev/null
  [[ "$(q "select count(*) from task_links where session = '\''tsess2'\''")" == 0 \
  && "$(q "select count(*) from sessions where name = '\''tsess2'\''")" == 1 ]]'
refute "unlink of a name that is no session fails" env WTS_NO_THINGS=1 "$WTS" task unlink zzqqx
"$WTS" rm tsess2 -f >/dev/null

# ─── Context kept ON the task ────────────────────────────────────────────────
# The point of task_notes and task_docs: they are what a task carries between
# its sessions, so they must survive both a Things refresh and a teardown.

tt() { env WTS_NO_THINGS=1 "$WTS" task "$@" }

# How many times a command opens Things' container. On macOS 15+ each open is an
# "access data from other apps" prompt, so the count IS the user-visible
# behaviour. The stub records the verb and answers "nothing", which is what a
# machine without Things answers anyway.
cat > "$SANDBOX/things-stub" <<'STUB'
#!/usr/bin/env zsh
print -r -- "$1" >> "$WTS_THINGS_LOG"
exit 1
STUB
chmod +x "$SANDBOX/things-stub"
export WTS_THINGS_LOG="$SANDBOX/things-opens"
opens() {  # <command…> -> the verbs it asked Things for, one per line
  : > "$WTS_THINGS_LOG"
  env WTS_THINGS_BIN="$SANDBOX/things-stub" "$@" >/dev/null 2>&1
  cat "$WTS_THINGS_LOG"
}
check "a local task never opens Things: there is nothing there for it" eval '
  [[ -z "$(opens "$WTS" task show "$TASK")" ]] \
  && [[ -z "$(opens "$WTS" task resolve "$TASK")" ]]'
q "insert or replace into tasks (id, source, title, synced_at)
      values ('ABC123abc456DEF789xyz', 'things', 'A task from Things', '2026-01-01T00:00:00Z')"
check "wts task ls refreshes every snapshot in one read, not one per task" eval '
  log=$(opens "$WTS" task ls --all)
  [[ "$(print -r -- "$log" | grep -c .)" == 1 && "$log" == "tasks" ]]'
# Into a file and not through `grep -q`: grep leaves as soon as it matches, wts
# dies of SIGPIPE writing the rest, and pipefail makes that the check's verdict.
check "and it still lists what the database holds" eval '
  env WTS_THINGS_BIN="$SANDBOX/things-stub" "$WTS" task ls --all > "$SANDBOX/ls-out" 2>&1
  grep -q "A task from Things" "$SANDBOX/ls-out"'
check "and lists two tasks without leaking its own variables between them" eval '
  [[ "$(grep -c "^[a-z_]*=" "$SANDBOX/ls-out")" == 0 ]]'
q "delete from tasks where id = 'ABC123abc456DEF789xyz'"
unset WTS_THINGS_LOG

check "task note appends, dated" eval '
  tt note "$TASK" "the audit table needs an index" >/dev/null
  tt note "$TASK" "finance wants a CSV export" >/dev/null
  [[ "$(q "select count(*) from task_notes where task = '\''$TASK'\''")" == 2 ]]'
check "task show prints them, labelled as added in wts" eval '
  out=$(tt show "$TASK")
  [[ "$out" == *"notes added in wts"* && "$out" == *"CSV export"* ]]'
# The regression these two tables exist to prevent: snapshot() overwrites every
# column it reads from Things, so notes kept in a column would be wiped by the
# next `wts task ls`. Simulated by writing the columns snapshot() writes.
check "a refresh of the task does not wipe them" eval '
  q "update tasks set notes = '\''rewritten from Things'\'', links = json('\''[]'\'') where id = \"$TASK\"" >/dev/null
  [[ "$(q "select count(*) from task_notes where task = '\''$TASK'\''")" == 2 ]]'
# `wts task note` is a verb an agent runs without a prompt: what it may do
# there is add. --clear deletes every note of the task, whoever wrote it.
check "task note --clear without a terminal: exit 2, the notes kept" eval '
  tt note "$TASK" --clear </dev/null 2>/dev/null; (( $? == 2 )) \
  && [[ "$(q "select count(*) from task_notes where task = '\''$TASK'\''")" == 2 ]]'
check "task note with no text is a usage error, exit 2" eval '
  tt note "$TASK" </dev/null 2>/dev/null; (( $? == 2 ))'
# Named explicitly: `wts doc add` derives a slug from the document's own title,
# and the point here is the task↔slug row, not the naming.
"$WTS" doc add "$SPEC" --name taskspec >/dev/null
# `edit` needs a terminal and the smoke test has none, so what is asserted here is
# the refusal — a vi opened on a pipe leaves the terminal unusable, which is worse
# than not editing. The buffer it builds is covered by the separator: db_rows
# TERMINATES rows with \x1e, and stripping it ran the notes together.
check "task edit without a terminal refuses, and says what to use" eval '
  out=$(tt edit "$TASK" 2>&1 </dev/null) && false
  [[ "$out" == *"needs a terminal"* && "$out" == *"wts task note"* ]]'
check "task doc attaches a library slug to the task" eval '
  tt doc "$TASK" taskspec >/dev/null
  [[ "$(q "select slug from task_docs where task = '\''$TASK'\''")" == taskspec ]]'
check "task docs lists it for the creation path" eval '
  [[ "$(tt docs "$TASK")" == taskspec ]]'
check "attaching it twice does not list it twice" eval '
  tt doc "$TASK" taskspec >/dev/null
  [[ "$(q "select count(*) from task_docs where task = '\''$TASK'\''")" == 1 ]]'
check "task doc --rm detaches it again" eval '
  tt doc "$TASK" --rm taskspec >/dev/null
  [[ "$(q "select count(*) from task_docs where task = '\''$TASK'\''")" == 0 ]]
  tt doc "$TASK" taskspec >/dev/null'

# All four channels at once: this is what "creating a session from a task
# inherits its context" means.
env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tctx smoke --task "$TASK" >/dev/null
check "the task title becomes the prompt when no phrase was typed" eval '
  [[ "$(reg_field tctx prompt)" == "Ship the audit trail" ]]'
check "the task section opens the context file" eval '
  grep -qF "## Task: Ship the audit trail" "$WT/tctx/.wts/context.md"'
check "the notes kept in wts are in it" eval '
  grep -qF "finance wants a CSV export" "$WT/tctx/.wts/context.md"'
check "the documents attached to the task are in it" eval '
  grep -qF "idempotent" "$WT/tctx/.wts/context.md" \
  && [[ "$(q "select json_array_length(docs) from sessions where name = '\''tctx'\''")" -ge 1 ]]'
# The one channel that survives /clear and /compact, so the one that has to
# repeat what the other three said once.
check "the SessionStart hook repeats the task context" eval '
  out=$(cd "$WT/tctx" && "$ROOT/libexec/wts/wts-context" </dev/null)
  [[ "$out" == *"Ship the audit trail"* && "$out" == *"CSV export"* ]]'
# A Things task can carry a pasted log: its notes were the one field the hook
# printed whole, at every start, /clear and /compact.
long_task_notes_capped() {
  local out
  q "INSERT OR REPLACE INTO kv VALUES ('smoke.notes', (SELECT notes FROM tasks WHERE id = '$TASK'))"
  q "UPDATE tasks SET notes = '$(printf 'line %d\n' {1..20})' WHERE id = '$TASK'"
  out=$(cd "$WT/tctx" && "$ROOT/libexec/wts/wts-context" </dev/null)
  q "UPDATE tasks SET notes = (SELECT value FROM kv WHERE key = 'smoke.notes') WHERE id = '$TASK'"
  [[ "$out" == *"line 12"* && "$out" != *"line 13"* && "$out" == *"8 more line(s)"* ]]
}
check "the hook caps the task's own notes" long_task_notes_capped
check "WTS_CONTEXT_QUIET keeps who and which task, nothing else" eval '
  out=$(cd "$WT/tctx" && WTS_CONTEXT_QUIET=1 "$ROOT/libexec/wts/wts-context" </dev/null)
  [[ "$out" == *"session \`tctx\`"* && "$out" == *"Task: **Ship the audit trail**"* \
     && "$out" != *"CSV export"* && "$out" != *"db set"* ]]'
check "a task with notes but no document still gets a context file" eval '
  T2=$(tt new "Rate-limit the public API")
  tt note "$T2" "per key, not per IP" >/dev/null
  env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tnodoc smoke --task "$T2" >/dev/null
  grep -qF "per key, not per IP" "$WT/tnodoc/.wts/context.md"'
"$WTS" rm tnodoc -f >/dev/null
check "the context they carry outlives the session" eval '
  "$WTS" rm tctx -f >/dev/null
  [[ "$(q "select count(*) from task_notes where task = '\''$TASK'\''")" == 2 \
  && "$(q "select count(*) from task_docs  where task = '\''$TASK'\''")" == 1 ]]'
# --task through `wts new`: strip_doc_args has always read WTS_TASK_ARG, and
# nothing ever set it, so every batch session was created linked to nothing.
check "wts new --task links every session it creates" eval '
  env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" new -p smoke tbatch1 tbatch2 --task "$TASK" >/dev/null
  [[ "$(q "select count(*) from task_links where task = '\''$TASK'\''")" == 2 ]]'
"$WTS" rm tbatch1 -f >/dev/null
"$WTS" rm tbatch2 -f >/dev/null
# An option cannot come first — the stray-option guard runs before any parsing —
# and `wts --task <id>` is the obvious thing to try. It must say which, not
# report an unknown option, and it must create nothing.
check "--task first is named, not reported as unknown" eval '
  out=$(env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" --task "$TASK" 2>&1) && false
  [[ "$out" == *"does not name one"* && "$out" != *"unknown option"* ]]'
refute "and it creates nothing" test -e "$WT/--task"

# ─── Tasks in the switcher ───────────────────────────────────────────────────
# The task rows share the session table, so every layout invariant asserted
# above has to hold with one on screen — and a task must never be mistaken for a
# session by the binds that take field 3.
check "an open task with no session is listed" eval '
  "$SWITCH" --list | cut -f2 | grep -q "^task:"'
check "both producers list it, or the swap would shift every row" eval '
  diff <("$SWITCH" --list-fast | cut -f2 | sort) <("$SWITCH" --list | cut -f2 | sort)'
check "a task row carries no session name" eval '
  "$SWITCH" --list | awk -F "\t" "\$2 ~ /^task:/ && \$3 != \"\" { exit 1 }"'
check "the rows are still 3 TAB fields with a task among them" eval '
  "$SWITCH" --list | awk -F "\t" "NF != 3 { exit 1 }" \
  && "$SWITCH" --list-fast | awk -F "\t" "NF != 3 { exit 1 }"'
check "and still padded to the list width" eval '
  WTS_SWITCH_COLS=60 "$SWITCH" --list | same_width 60 \
  && WTS_SWITCH_COLS=60 "$SWITCH" --list-fast | same_width 60'
check "the task preview is what the task carries" eval '
  tid=$("$SWITCH" --list | awk -F "\t" "\$2 ~ /^task:/ { print substr(\$2, 6); exit }")
  out=$("$SWITCH" --preview "task:$tid" "")
  [[ "$out" == *"## Task:"* && "$out" == *"attach it to a session"* ]]'
check "WTS_SWITCH_TASKS=0 keeps them out" eval '
  ! env WTS_SWITCH_TASKS=0 "$SWITCH" --list | cut -f2 | grep -q "^task:"'
# A served task stays listed: its row is the only way to start a second session
# on it from the popup. It used to leave the list at its first session.
env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tserved smoke --task "$TASK" >/dev/null
check "a task a session serves stays listed, with its session count" eval '
  row=$("$SWITCH" --list | awk -F "\t" -v t="task:$TASK" "\$2 == t && \$3 == \"\"")
  [[ "$row" == *"1 session(s)"* ]]'
check "both producers list the served task" eval '
  diff <("$SWITCH" --list-fast | cut -f2 | sort) <("$SWITCH" --list | cut -f2 | sort)'
check "the task preview names the session serving it" eval '
  out=$("$SWITCH" --preview "task:$TASK" "")
  [[ "$out" == *"Sessions on it now:"* && "$out" == *"- tserved "* ]]'
"$WTS" rm tserved -f >/dev/null
check "and still names it once it is archived, with its outcome" eval '
  out=$("$SWITCH" --preview "task:$TASK" "")
  [[ "$out" == *"- tserved ("*")"* ]]'
# A retry starts where the last attempt stopped: the retrospective lines a
# retry needs reach the preview, task show, the context file and the hook. Only
# `delivered` used to, and only in the first two.
q "UPDATE archive SET retro_delivered = 'half the form', retro_resisted = 'the date picker',
     retro_resolved = '-', retro_abandoned = 'the i18n pass' WHERE session = 'tserved'"
check "the task preview carries the last attempt's retrospective" eval '
  out=$("$SWITCH" --preview "task:$TASK" "")
  [[ "$out" == *"resisted: the date picker"* && "$out" != *"resolved: -"* ]]'
check "task show prints every retrospective line, not delivered alone" eval '
  out=$(tt show "$TASK" </dev/null)
  [[ "$out" == *"resisted: the date picker"* && "$out" == *"abandoned: the i18n pass"* ]]'
env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tretry smoke --task "$TASK" >/dev/null
check "a new session on the task opens on the previous attempt" \
  grep -qF "resisted: the date picker" "$WT/tretry/.wts/context.md"
check "and the hook repeats it after every /clear" eval '
  out=$(cd "$WT/tretry" && "$ROOT/libexec/wts/wts-context" </dev/null)
  [[ "$out" == *"Previous attempts"* && "$out" == *"tserved (abandoned"* ]]'
# The session preview: the cached brief and the agent's last two notes above the
# pane, read from the database and never from the model.
q "INSERT INTO briefs VALUES ('tretry', 'k', 'done: wired the form' || char(10) || 'next: pick a date lib', strftime('%s','now') - 7200);
   INSERT INTO notes VALUES ('tretry', 'oldest', 'not shown', '2020-01-01T00:00:00Z'),
                            ('tretry', 'schema', 'added a column', strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minutes')),
                            ('tretry', 'api', 'renamed the route', strftime('%Y-%m-%dT%H:%M:%SZ','now'))"
check "the session preview shows its brief, with its age" eval '
  out=$(FZF_PREVIEW_LINES=40 FZF_PREVIEW_COLUMNS=100 "$SWITCH" --preview tretry tretry)
  [[ "$out" == *"done: wired the form (2h0m)"* && "$out" == *"next: pick a date lib"* ]]'
check "and the last two notes its agent left, not the older ones" eval '
  out=$(FZF_PREVIEW_LINES=40 FZF_PREVIEW_COLUMNS=100 "$SWITCH" --preview tretry tretry)
  [[ "$out" == *"note api"*"renamed the route"* && "$out" == *"note schema"* && "$out" != *"not shown"* ]]'
# Its stderr kept, and the pane printed under the memos: a failing expansion in
# the rule once ended the preview there, silently for the checks above.
# echo, not print: the pane runs the login shell, bash on the Linux runner.
tmux send-keys -t "=tretry:" "echo pane-marker" Enter
check "and the pane itself below them" eval '
  pane_shows tretry pane-marker
  out=$(FZF_PREVIEW_LINES=40 FZF_PREVIEW_COLUMNS=100 "$SWITCH" --preview tretry tretry 2>&1)
  [[ "$out" == *"next: pick a date lib"*"pane-marker"* && "$out" != *"bad substitution"* ]]'
check "a short preview keeps the pane rather than the memos" eval '
  out=$(FZF_PREVIEW_LINES=8 "$SWITCH" --preview tretry tretry)
  [[ "$out" != *"wired the form"* ]]'
"$WTS" rm tretry -f >/dev/null
# tab on a task pins the task, and enter appends to its notes instead of typing
# into a pane there is none of.
export WTS_SWITCH_REPLY="$SANDBOX/reply-task"
rm -f "$WTS_SWITCH_REPLY"
check "tab on a task enters note mode" eval '
  chain=$("$SWITCH" --reply toggle "task:$TASK" "")
  [[ "$chain" == *"change-prompt|note on Ship the audit trail> |"* ]] \
  && [[ "$(head -1 "$WTS_SWITCH_REPLY")" == "task:$TASK" ]]'
check "enter appends the line to the task" eval '
  "$SWITCH" --reply send "typed from the switcher" "task:$TASK" "" >/dev/null
  [[ -n "$(q "select 1 from task_notes where task = '\''$TASK'\'' and body = '\''typed from the switcher'\''")" ]]'
check "the footer says append, not send" eval '
  [[ "$(env WTS_SWITCH_COLS=120 "$ROOT/libexec/wts/wts-keys" --footer note)" == *"enter append"* ]]'
"$SWITCH" --reply esc >/dev/null
unset WTS_SWITCH_REPLY
# The bind that had to move: `wts rm ""` matches every session by substring and
# opens a picker offering to delete any of them, and a task row hands it "".
check "ctrl-d goes through --rm, not straight to wts rm" \
  grep -qF "ctrl-d:execute('\$self' --rm {3} {2} {1})" "$SWITCH"
check "--rm on a row that is neither a session nor a task does nothing at all" eval '
  n=$(q "select count(*) from sessions")
  "$SWITCH" --rm "" "" >/dev/null 2>&1 </dev/null
  [[ "$(q "select count(*) from sessions")" == "$n" ]]'
# ctrl-t: a task created from the popup. The mode is reply mode's machinery,
# pinned on `newtask:`; enter creates a local task and hands `load` its id.
export WTS_SWITCH_REPLY="$SANDBOX/reply-new" WTS_SWITCH_FOCUS="$SANDBOX/focus"
rm -f "$WTS_SWITCH_REPLY" "$WTS_SWITCH_FOCUS"
chain=$(env WTS_NO_THINGS=1 "$SWITCH" --reply new)
check "ctrl-t enters new-task mode" eval '
  [[ "$chain" == disable-search+* && "$chain" == *"change-prompt(new task> )"* ]] \
  && [[ "$(head -1 "$WTS_SWITCH_REPLY")" == "newtask:" ]]'
check "fzf parses the new-task chain" fzf_parses "$chain"
check "the new-task footer says create" eval '
  [[ "$(env WTS_SWITCH_COLS=120 "$ROOT/libexec/wts/wts-keys" --footer newtask)" == "enter create"* ]]'
# Under ctrl-g's view, which lists no task: the new one could not be focused.
export WTS_SWITCH_VIEW="$SANDBOX/view"
: > "$WTS_SWITCH_VIEW"
check "the needs-you view hides the task rows" eval '
  out=$("$SWITCH" --list | cut -f2); [[ "$out" != *task:* ]]'
chain=$("$SWITCH" --reply send "  Write the migration guide " "" "")
NEWTASK=$(q "select id from tasks where title = 'Write the migration guide'")
check "enter creates a local task, trimmed" eval '[[ "$NEWTASK" == local:* ]]'
check "and turns the view back to every row, to show it" eval '
  [[ ! -e "$WTS_SWITCH_VIEW" && "$chain" == *"change-prompt(session> )"* ]]'
unset WTS_SWITCH_VIEW
check "and leaves the mode, reloading with load rebound" eval '
  [[ ! -e "$WTS_SWITCH_REPLY" && "$chain" == enable-search+* \
     && "$chain" == *"rebind(load)+reload-sync("* ]]'
check "fzf parses the create chain" fzf_parses "$chain"
check "load then puts the cursor on the new task" eval '
  n=$("$SWITCH" --loaded)
  row=$("$SWITCH" --list-fast | sed -n "$(( ${${n#*pos\(}%\)} + 2 ))p" | cut -f2)
  [[ "$n" == "unbind(load)+pos("* && "$row" == "task:$NEWTASK" && ! -e "$WTS_SWITCH_FOCUS" ]]'
check "and the next load is the startup reload again" eval '
  [[ "$("$SWITCH" --loaded --no-git)" == *"reload-sync("*"--list --no-git)" ]]'
ntasks=$(q "select count(*) from tasks")
"$SWITCH" --reply new >/dev/null
chain=$(env WTS_SWITCH_THINGS= "$SWITCH" --reply send "   " "" "")
check "an empty title without Things only leaves the mode" eval '
  [[ "$chain" != *execute* && "$chain" != *reload-sync* && ! -e "$WTS_SWITCH_REPLY" ]] \
  && [[ "$(q "select count(*) from tasks")" == "$ntasks" ]]'
"$SWITCH" --reply new >/dev/null
check "an empty title with Things opens its picker" eval '
  [[ "$(env WTS_SWITCH_THINGS=1 "$SWITCH" --reply send "" "" "")" == *"execute("*"--things)"* ]]'
"$SWITCH" --reply new >/dev/null
check "and so does an unprobed Things, which is what finds out" eval '
  [[ "$(env WTS_SWITCH_THINGS=maybe "$SWITCH" --reply send "" "" "")" == *"execute("*"--things)"* ]]'
unset WTS_SWITCH_REPLY WTS_SWITCH_FOCUS
check "wts keys lists ^t as a new task, Things or not" eval '
  env WTS_SWITCH_COLS=120 "$ROOT/libexec/wts/wts-keys" --footer expanded | grep -qF "new task"'

# enter on a task: the choice screen's answers, without the screen.
ta() { env WTS_SWITCH_DRY=1 WTS_NO_THINGS=1 "$SWITCH" --task-action "$NEWTASK" "$@" }
check "a prompt starts wts-fresh on the phrase, linked to the task" eval '
  [[ "$(ta prompt "write the migration guide")" == "wts-fresh '\''write the migration guide'\'' --task $NEWTASK" ]]'
refute "a one-word prompt is refused, it would be read as a name" ta prompt status
# The prefix is the `default` layout's, the one the session starts on: the
# built-in one has none, so `feature/` is not stripped (and a `/` cannot be in a
# session name) rather than promised and dropped.
refute "without a prefix in the layout, feature/ is not stripped" ta branch feature/migration-guide
check "a branch name loses the layout's prefix typed by habit" eval '
  print -r -- "# wts: branch_prefix=feature/" > "$XDG_CONFIG_HOME/wts/layouts/default.yml"
  cat "$ROOT/share/wts/layouts/default.yml" >> "$XDG_CONFIG_HOME/wts/layouts/default.yml"
  out=$(ta branch feature/migration-guide); rm -f "$XDG_CONFIG_HOME/wts/layouts/default.yml"
  [[ "$out" == "wts-fresh migration-guide --task $NEWTASK" ]]'
check "and WTS_BRANCH_PREFIX's" eval '
  [[ "$(WTS_BRANCH_PREFIX=me/ ta branch me/migration-guide)" == "wts-fresh migration-guide --task $NEWTASK" ]]'
refute "a branch that cannot be a session name is refused" ta branch "Migration Guide"
check "attaching links the task to the session" eval '
  env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" tattach smoke >/dev/null
  [[ "$(ta session tattach)" == "switch tattach" ]] \
  && [[ "$(q "select task from task_links where session = '\''tattach'\''")" == "$NEWTASK" ]]'
check "and the task keeps its row, to start another session on it" eval '
  "$SWITCH" --list | cut -f2 | grep -qxF "task:$NEWTASK"'
"$WTS" rm tattach -f >/dev/null

# The way out of the list. Without it a local task stayed open for good, and came
# back after every session on it was removed — which is what happens just above.
check "a task whose session was removed is back among the task rows" eval '
  "$SWITCH" --list | cut -f2 | grep -qxF "task:$NEWTASK"'
check "task done closes a local task" eval '
  tt done "$NEWTASK" >/dev/null
  [[ "$(q "select status from tasks where id = '\''$NEWTASK'\''")" == completed ]] \
  && [[ -n "$(q "select completed_at from tasks where id = '\''$NEWTASK'\''")" ]]'
refute "and it leaves the task rows for good" eval '
  "$SWITCH" --list | cut -f2 | grep -qxF "task:$NEWTASK"'
check "its history stays: the archived session still names it" eval '
  [[ "$(q "select count(*) from archive where task = '\''$NEWTASK'\''")" -ge 1 ]]'
check "done twice is not an error" eval '
  [[ "$(tt done "$NEWTASK")" == *"already done"* ]]'
check "a Things task is refused, and left open" eval '
  q "insert into tasks (id, source, title, status, synced_at) values ('\''THINGSdone0123456789ab'\'', '\''things'\'', '\''From Things'\'', '\''open'\'', '\''x'\'')"
  out=$(tt done THINGSdone0123456789ab 2>&1) && false
  [[ "$out" == *"complete it in Things"* ]] \
  && [[ "$(q "select status from tasks where id = '\''THINGSdone0123456789ab'\''")" == open ]]'
q "delete from tasks where id = 'THINGSdone0123456789ab'"
check "done with no id outside a session says why" eval '
  out=$(cd "$SANDBOX" && tt done 2>&1) && false
  [[ "$out" == *"not inside a wts session"* ]]'

# ─── rm: the destructive verb takes nothing on trust ─────────────────────────
# Every path here used to reach a deletion nobody asked for: the wrong worktree
# (or none, with the registry row dropped anyway), a session guessed from a
# typo, a session of another repository, an agent killed before git refused a
# dirty worktree. Each check is the regression that would have caught it.

cd "$REPO"
env WTS_NO_ATTACH=1 "$WTS" safe-a smoke >/dev/null
env WTS_NO_ATTACH=1 "$WTS" safe-b smoke >/dev/null

# From inside a worktree, `--show-toplevel` is that worktree: rm derived
# `<worktree>-worktrees/<name>` from it, found nothing there, and forgot the
# session while its worktree and branch stayed behind.
check "rm from inside another worktree removes the right worktree" eval '
  (cd "$WT/safe-a" && "$WTS" rm safe-b -f >/dev/null)
  [[ ! -e "$WT/safe-b" && -d "$WT/safe-a" ]] \
  && [[ "$(q "select count(*) from archive where session = '\''safe-b'\''")" == 1 ]]'
refute "and drops its registry entry" in_registry safe-b
check "creating from inside a worktree lands in the repository's worktree base" eval '
  (cd "$WT/safe-a" && env WTS_NO_ATTACH=1 "$WTS" safe-nested smoke >/dev/null)
  [[ -d "$WT/safe-nested" && ! -e "$WT/safe-a-worktrees" ]]'
"$WTS" rm safe-nested -f >/dev/null

# A guessed name. The resolver matches substrings both ways: `api-v2` with no
# such session resolved to `api`, and -f removed it.
env WTS_NO_ATTACH=1 "$WTS" api smoke >/dev/null
refute "rm of a name that only resembles a session refuses when not interactive" \
  eval '"$WTS" rm api-v2 -f </dev/null'
check "and the session it resembled is intact" eval '[[ -d "$WT/api" ]] && in_registry api'
refute "rm of an empty name refuses" eval '"$WTS" rm "" -f </dev/null'
check "with every session still there" eval '[[ -d "$WT/api" && -d "$WT/safe-a" ]]'
refute "rm of an unknown name fails" eval '"$WTS" rm nothing-like-it -f </dev/null'
"$WTS" rm api -f >/dev/null

# A dirty worktree: the session was killed first, then git refused, and the
# agent was dead for nothing.
env WTS_NO_ATTACH=1 "$WTS" safe-dirty smoke >/dev/null
print "wip" > "$WT/safe-dirty/wip.txt"
refute "rm of a dirty worktree refuses without -f" eval '"$WTS" rm safe-dirty </dev/null'
check "and its session is still running" has_session safe-dirty
check "rm -f takes the changes with it" eval '
  "$WTS" rm safe-dirty -f >/dev/null; [[ ! -e "$WT/safe-dirty" ]]'

# Another repository. The switcher lists every session; rm used the repository
# at hand, found nothing, and forgot the other one's session.
REPO2="$SANDBOX/code/other"
WT2="$SANDBOX/code/other-worktrees"
mkdir -p "$REPO2"
git -C "$REPO2" init -q
print other > "$REPO2/README"
git -C "$REPO2" add README
git -C "$REPO2" commit -qm init
(cd "$REPO2" && env WTS_NO_ATTACH=1 "$WTS" other-sess smoke >/dev/null)
check "rm from another repository removes the session's own worktree" eval '
  "$WTS" rm other-sess -f >/dev/null
  [[ ! -e "$WT2/other-sess" ]] \
  && ! git -C "$REPO2" show-ref --verify --quiet refs/heads/feature/other-sess'
refute "and its registry entry" in_registry other-sess
# A name already used by another repository overwrote its registry row, then
# attached to its tmux session.
refute "an explicit name that is a session of another repository is refused" \
  eval '(cd "$REPO2" && env WTS_NO_ATTACH=1 "$WTS" safe-a smoke </dev/null)'
check "and the registry still points at the first repository" eval '
  [[ "$(reg_field safe-a worktree)" == "$WT/safe-a" && ! -e "$WT2/safe-a" ]]'

# A worktree removed by hand: `wts ls` dropped the row, the notes and the task
# link, and no archive row said the work had ever existed.
env WTS_NO_ATTACH=1 "$WTS" safe-gone smoke >/dev/null
tmux kill-session -t "=safe-gone"
rm -rf "$WT/safe-gone"
check "ls archives a session whose worktree vanished, then forgets it" eval '
  "$WTS" ls >/dev/null 2>&1
  [[ "$(q "select outcome from archive where session = '\''safe-gone'\''")" == unknown ]]'
refute "and the registry entry is gone" in_registry safe-gone

# `wts rm` on the same state dropped the row with nothing archived: which of
# the two commands came first decided whether the session left a trace.
env WTS_NO_ATTACH=1 "$WTS" safe-gone2 smoke >/dev/null
(cd "$WT/safe-gone2" && "$WTS" db set left "kept by rm too" >/dev/null 2>&1) || true
tmux kill-session -t "=safe-gone2"
rm -rf "$WT/safe-gone2"
check "rm of a session whose worktree vanished archives it too, notes included" eval '
  "$WTS" rm safe-gone2 -f >/dev/null 2>&1
  [[ "$(q "select outcome from archive where session = '\''safe-gone2'\''")" == abandoned \
     && "$(q "select notes from archive where session = '\''safe-gone2'\''")" == *"kept by rm too"* ]]'
refute "and forgets it" in_registry safe-gone2

# A listing run while `wts rm` is between "worktree removed" and "archived" saw
# a row with no worktree, archived it `unknown` and deleted it: rm's own record,
# the one with the outcome, was then refused. rm marks the row for a minute.
env WTS_NO_ATTACH=1 "$WTS" safe-tear smoke >/dev/null
tmux kill-session -t "=safe-tear"
mv "$WT/safe-tear" "$WT/safe-tear.away"
q "INSERT OR REPLACE INTO kv VALUES ('teardown:safe-tear', strftime('%s', 'now'))"
check "ls leaves alone a session rm is tearing down" eval '
  "$WTS" ls >/dev/null 2>&1; in_registry safe-tear'
q "UPDATE kv SET value = value - 120 WHERE key = 'teardown:safe-tear'"
check "and takes it once the mark is over a minute old" eval '
  "$WTS" ls >/dev/null 2>&1; ! in_registry safe-tear'
check "the mark goes with the row" eval '[[ -z "$(q "SELECT 1 FROM kv WHERE key = '\''teardown:safe-tear'\''")" ]]'
mv "$WT/safe-tear.away" "$WT/safe-tear"
git -C "$REPO" worktree remove --force "$WT/safe-tear" >/dev/null 2>&1 || true
git -C "$REPO" branch -D feature/safe-tear >/dev/null 2>&1 || true

# A name used again for other work. The row is keyed on the name and
# registry_put upserts: with the old row still there (its worktree and branch
# removed through git, or a `wts rm` whose delete failed), the new session was
# born with the old one's creation date, notes and events.
env WTS_NO_ATTACH=1 "$WTS" safe-again smoke >/dev/null
(cd "$WT/safe-again" && "$WTS" db set old "from the first life" >/dev/null 2>&1) || true
first_born=$(reg_field safe-again created_at)
tmux kill-session -t "=safe-again"
git -C "$REPO" worktree remove --force "$WT/safe-again" >/dev/null 2>&1 || true
git -C "$REPO" branch -D feature/safe-again >/dev/null 2>&1 || true
sleep 1
env WTS_NO_ATTACH=1 "$WTS" safe-again smoke >/dev/null 2>&1 || true
check "a name used again inherits no note" eval '
  in_registry safe-again && [[ "$(q "select count(*) from notes where session = '\''safe-again'\''")" == 0 ]]'
check "its first life is archived, notes included" eval '
  [[ "$(q "select notes from archive where session = '\''safe-again'\''")" == *"first life"* ]]'
check "and it has a creation date of its own" eval '[[ "$(reg_field safe-again created_at)" != "$first_born" ]]'
# The same name on the branch it had: the worktree brought back for the same
# work. The row, and what it carries, is that work's.
(cd "$WT/safe-again" && "$WTS" db set kept "same work" >/dev/null 2>&1) || true
tmux kill-session -t "=safe-again" 2>/dev/null || true
git -C "$REPO" worktree remove --force "$WT/safe-again" >/dev/null 2>&1 || true
env WTS_NO_ATTACH=1 "$WTS" safe-again smoke >/dev/null 2>&1 || true
check "a worktree brought back on its own branch keeps its row" eval '
  [[ "$(q "select value from notes where session = '\''safe-again'\'' and key = '\''kept'\''")" == "same work" ]]'
"$WTS" rm safe-again -f >/dev/null 2>&1 || true

# The hook names the task it tells the agent to look at: a bare `wts task show`
# opens the Things picker, which an agent may not. Created before the ctrl-d
# check below, so that this — not safe-a — is the server's most recent session.
T3=$(tt new "Name the task in the hook")
env WTS_NO_ATTACH=1 WTS_NO_THINGS=1 "$WTS" safe-task smoke --task "$T3" >/dev/null
check "the hook says which task to show" eval '
  out=$(cd "$WT/safe-task" && "$ROOT/libexec/wts/wts-context" </dev/null)
  [[ "$out" == *"task show $T3"* ]]'
# Captured, not piped into grep -q: grep quits at the first match, the lines
# after it hit a closed pipe, and pipefail read that as a failed command.
check "task show with no id inside a session shows that session's task" eval '
  out=$(cd "$WT/safe-task" && tt show </dev/null)
  [[ "$out" == *"Name the task in the hook"* ]]'

# The switcher's ctrl-d asks first, as ctrl-x already did, and names the agent
# state it shows. `read -q` reads the terminal, never stdin: with none (here),
# it fails and counts as no, so the only thing to check is that nothing went.
check "--rm on a session asks y/N before wts rm, and removes nothing unanswered" eval '
  grep -qF "read -q \"?Remove session" "$SWITCH"
  out=$("$SWITCH" --rm safe-a "safe-a" "safe-a  idle  feature/safe-a" </dev/null 2>&1)
  [[ "$out" != *"removed"* ]] && in_registry safe-a && [[ -d "$WT/safe-a" ]]'
"$WTS" rm safe-task -f >/dev/null
"$WTS" rm safe-a -f >/dev/null

# The refresher's delay is handed to sleep: formatted with a dot whatever the
# locale, or under fr_FR it was `12,3` and the loop ran with no delay at all.
check "the refresh delay is computed under LC_ALL=C" \
  grep -qF "LC_ALL=C printf '%.1f'" "$SWITCH"
cd "$REPO"

# ─── Agent events: wts-hook ──────────────────────────────────────────────────
# What the agent reports about itself through the Claude Code hooks: the
# state when claude cannot be asked (the stand-in `claude agents` answers []),
# since when, and what it waits for. WTS_NOTIFY=0 above: no bell, no banner.

HOOK="$ROOT/libexec/wts/wts-hook"
cd "$REPO"
env WTS_NO_ATTACH=1 "$WTS" evsess smoke >/dev/null
ev() { # <verb> <json> — the hook as Claude Code runs it: from the worktree, payload on stdin
  (cd "$WT/evsess" && print -r -- "$2" | "$HOOK" "$1")
}
ev_state() { "$WTS" status --json --no-git | jq -r '.[] | select(.name == "evsess") | .agent_state // "null"' }

check "a prompt event is recorded, and the hook prints nothing" eval '
  out=$(ev prompt "{\"session_id\":\"abc-123\",\"cwd\":\"$WT/evsess\"}")
  [[ -z "$out" ]] \
  && [[ "$(q "select count(*) from agent_events where session = '\''evsess'\'' and event = '\''prompt'\''")" == 1 ]]'
check "without claude agents, the state comes from the events" eval '
  "$WTS" status --json --no-git | jq -e "
    .[] | select(.name == \"evsess\")
    | .agent_state == \"working\" and .agent_source == \"events\" and (.agent_since | type) == \"number\""'
check "a notification that needs a human makes it blocked, with the question" eval '
  ev notification "{\"session_id\":\"abc-123\",\"notification_type\":\"permission_prompt\",\"message\":\"Bash: rm -rf dist\"}"
  "$WTS" status --json --no-git | jq -e "
    .[] | select(.name == \"evsess\")
    | .agent_state == \"blocked\" and .agent_waiting_for == \"Bash: rm -rf dist\""'
check "the status line counts it" eval '
  [[ "$("$ROOT/libexec/wts/wts-status" --line)" == *"1 blocked"* ]]'
check "the switcher preview opens on the state and the question" eval '
  export WTS_SWITCH_META="$SANDBOX/switch-meta"
  "$SWITCH" --list >/dev/null
  out=$("$SWITCH" --preview evsess evsess)
  l=("${(@f)out}")
  [[ "${l[1]}" == "blocked "*": Bash: rm -rf dist" ]]'
unset WTS_SWITCH_META
# Among the blocked, the oldest question first: that is where prefix+a lands.
env WTS_NO_ATTACH=1 "$WTS" evold smoke >/dev/null
q "insert into agent_events (session, claude_session, event, kind, message, at)
   values ('evold', 'old-1', 'notification', 'permission_prompt', 'older question', strftime('%s','now') - 600)"
check "among the blocked, the one waiting longest comes first" eval '
  [[ "$("$WTS" status --json --no-git | jq -r "map(select(.agent_state == \"blocked\")) | .[0].name")" == evold ]]'
check "a stop makes it idle" eval '
  ev stop "{\"session_id\":\"abc-123\"}"
  [[ "$(ev_state)" == idle ]]'
check "and the status line says so" eval '
  line=$("$ROOT/libexec/wts/wts-status" --line)
  [[ "$line" == *"1 blocked"* && "$line" == *"1 idle"* ]]'
# An agent that quits says so: stopped. It used to leave no state at all, which
# `wts wait` reads as "not started yet" — waiting for an agent that had quit
# timed out every time, and the advice was to call it again.
check "an end event reads stopped" eval '
  ev end "{\"session_id\":\"abc-123\",\"reason\":\"other\"}"
  "$WTS" status --json --no-git | jq -e "
    .[] | select(.name == \"evsess\")
    | .agent_state == \"stopped\" and .agent_source == \"events\" and (.agent_since | type) == \"number\""'
check "a day later too: the twelve-hour doubt is for agents that said nothing" eval '
  q "UPDATE agent_events SET at = at - 90000 WHERE session = '\''evsess'\''"
  [[ "$(ev_state)" == stopped ]]'
check "wait returns on it, its tmux session still alive" eval '
  has_session evsess && "$WTS" wait evsess --timeout 2 --json </dev/null \
    | jq -e ".reached and .sessions[0].state == \"stopped\""'
# Without the start hook (an install not set up again since), a /clear is an
# end of reason clear alone: still idle, the agent is there.
check "an end of kind clear with no start after it reads idle" eval '
  ev end "{\"session_id\":\"abc-123\",\"reason\":\"clear\"}"
  [[ "$(ev_state)" == idle ]]'
# With it, a /clear is an end then a start, in the same second: the start is the word.
check "a /clear ends the conversation, not the agent: idle" eval '
  ev end "{\"session_id\":\"abc-123\",\"reason\":\"clear\"}"
  ev start "{\"session_id\":\"abc-456\",\"source\":\"clear\"}"
  [[ "$(ev_state)" == idle ]]'
check "the start is recorded with its source, and its conversation is the agent's" eval '
  [[ "$(q "select kind from agent_events where session = '\''evsess'\'' and event = '\''start'\''")" == clear ]] \
  && "$WTS" status --json --no-git | jq -e ".[] | select(.name == \"evsess\") | .agent_session == \"abc-456\""'
# The roadmap bug: claude quit, then run again in the same pane, read stopped
# until its first prompt, and `wts send` needed --force.
ev end '{"session_id":"abc-456","reason":"other"}'
check "an end after it reads stopped again" eval '[[ "$(ev_state)" == stopped ]]'
q "UPDATE agent_events SET at = at - 5 WHERE session = 'evsess'"
check "an agent started again after an end reads idle, since its start" eval '
  ev start "{\"session_id\":\"abc-789\",\"source\":\"startup\"}"
  st=$(q "select max(at) from agent_events where session = '\''evsess'\'' and event = '\''start'\''")
  "$WTS" status --json --no-git | jq -e --argjson st "$st" "
    .[] | select(.name == \"evsess\") | .agent_state == \"idle\" and .agent_since == \$st"'
check "a compaction leaves the state alone" eval '
  ev prompt "{\"session_id\":\"abc-789\"}"
  ev start "{\"session_id\":\"abc-789\",\"source\":\"compact\"}"
  [[ "$(ev_state)" == working ]]'
# A message from another Claude session (SendMessage) is a prompt too: the
# hook records it with kind message and the sender; the idle notice of
# notify_when_idle likewise. Prompts as measured on Claude Code 2.1.293.
check "a message from another session: a prompt of kind message, from its sender" eval '
  ev prompt "$(jq -n "{session_id: \"abc-789\", prompt: \"<cross-session-message from=\\\"uds:/tmp/cc-socks/1.sock\\\" from-name=\\\"rate-limit\\\" from-mode=\\\"prompting\\\">\\nis /login done?\\n</cross-session-message>\"}")"
  [[ "$(q "select kind || \"|\" || message from agent_events where session = '\''evsess'\'' and event = '\''prompt'\'' order by id desc limit 1")" == "message|from rate-limit" \
  && "$(ev_state)" == working ]]'
check "the idle notice too, with its text" eval '
  ev prompt "{\"session_id\":\"abc-789\",\"prompt\":\"[Cross-session idle notice] \\\"rate-limit\\\", which you asked to be notified about, is idle now\"}"
  [[ "$(q "select kind || \"|\" || message from agent_events where session = '\''evsess'\'' and event = '\''prompt'\'' order by id desc limit 1")" == "message|[Cross-session idle notice]"* ]]'
check "the author's own prompt keeps an empty kind" eval '
  ev prompt "{\"session_id\":\"abc-789\",\"prompt\":\"<command-name>/review</command-name> and fix it\"}"
  [[ -z "$(q "select kind from agent_events where session = '\''evsess'\'' and event = '\''prompt'\'' order by id desc limit 1")" ]]'
ev stop '{"session_id":"abc-789"}'
# wts brief: a sibling's message is neither the starting task nor the author's
# last message. A transcript shaped like Claude Code's: the inbound message is a
# user record with origin.kind peer, and may be the last prompt.
msg_tr="$SANDBOX/msg-transcript.jsonl"
cat > "$msg_tr" <<'JSONL'
{"type":"user","isMeta":true,"promptSource":"system","turnOrigin":"peer","origin":{"kind":"peer","name":"rate-limit"},"message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from-name=\"rate-limit\">\nstart with the 429\n</cross-session-message>"}}
{"type":"user","promptSource":"typed","turnOrigin":"human","origin":{"kind":"human"},"message":{"role":"user","content":"Add the retry header"}}
{"type":"last-prompt","lastPrompt":"Add the retry header"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done with the header."}]}}
{"type":"last-prompt","lastPrompt":"<cross-session-message from=\"uds:/x\" from-name=\"rate-limit\">\nis it done?\n</cross-session-message>"}
JSONL
q "UPDATE agent_panes SET transcript = '$msg_tr' WHERE session = 'evsess'"
q "UPDATE sessions SET prompt = '' WHERE name = 'evsess'"
brief_skips_peers() {
  local out
  out=$("$WTS" brief evsess 2>/dev/null </dev/null)
  [[ "$out" == *"task:  Add the retry header"* && "$out" == *"you:   Add the retry header"* \
     && "$out" != *"start with the 429"* && "$out" != *"is it done"* ]]
}
check "brief: the task and the author's last message are not a sibling's" brief_skips_peers
check "ls says since when, next to the state" eval '
  [[ "$("$WTS" ls | grep "^evsess ")" == "evsess "*" idle "[0-9]*s" "* ]]'
check "ls --wide says what a blocked agent waits for" eval '
  out=$("$WTS" ls --wide)
  [[ "${out%%$'\''\n'\''*}" == *MODEL*WAITING*SUBJECT* && "$(print -r -- "$out" | grep "^evold ")" == *"older question"* ]]'
check "outside a wts session the hook records nothing and exits 0" eval '
  n=$(q "select count(*) from agent_events")
  (cd "$SANDBOX" && print "{}" | "$HOOK" prompt) \
  && [[ "$(q "select count(*) from agent_events")" == "$n" ]]'
check "rm drops the session's events" eval '
  "$WTS" rm evsess -f >/dev/null
  [[ "$(q "select count(*) from agent_events where session = '\''evsess'\''")" == 0 ]]'
"$WTS" rm evold -f >/dev/null

# Restore resumes the conversation the hooks recorded, not the latest one in
# the directory, when its transcript is still there.
cat > "$XDG_CONFIG_HOME/wts/layouts/resume.yml" <<'EOF'
name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - main: echo "RESUME=<%= ENV['WTS_RESUME_ID'] %>/<%= ENV['WTS_RESUME'] %>"
EOF
env WTS_NO_ATTACH=1 "$WTS" evresume resume >/dev/null
(cd "$WT/evresume" && print -r -- '{"session_id":"0123abcd-ef01-2345-6789-abcdef012345"}' | "$HOOK" prompt)
"$WTS" stop evresume >/dev/null
proj="$CLAUDE_CONFIG_DIR/projects/$(print -r -- "$WT/evresume" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$proj" && print '{}' > "$proj/0123abcd-ef01-2345-6789-abcdef012345.jsonl"
"$WTS" restore evresume >/dev/null
check "restore pre-fills the conversation the hooks recorded" \
  pane_shows evresume "RESUME=0123abcd-ef01-2345-6789-abcdef012345/1"
# The events are swept after seven days; the pane row lasts as long as the
# session. Restore read only the events, and came back on `--continue`.
"$WTS" stop evresume >/dev/null
q "INSERT OR REPLACE INTO agent_panes (session, claude_session, pane, at)
   VALUES ('evresume', '0123abcd-ef01-2345-6789-abcdef012345', '%999', strftime('%s', 'now'))"
q "DELETE FROM agent_events WHERE session = 'evresume'"
"$WTS" restore evresume >/dev/null
check "and still does once its events are swept" \
  pane_shows evresume "RESUME=0123abcd-ef01-2345-6789-abcdef012345/1"
check "the default layout renders a --resume pre-fill" eval '
  env WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE=1 WTS_RESUME=1 \
    WTS_RESUME_ID=0123abcd-ef01-2345-6789-abcdef012345 WTS_DOC="" WTS_PROMPT="" \
    tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml" \
  | grep -qF "resume\\ 0123abcd-ef01-2345-6789-abcdef012345"'
check "the default layout names the conversation after the session" eval '
  out=$(env WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_DOC="" WTS_PROMPT="fix it" \
    tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml")
  [[ "$out" == *"claude\\ --name\\ render\\ "* ]]'
check "but not a name that would read as a flag" eval '
  out=$(env WTS_NAME="-x" WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_DOC="" WTS_PROMPT="" \
    tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml")
  [[ "$out" == *"claude C-m"* && "$out" != *"--name"* ]]'
check "nor on restore: the resumed conversation keeps its own" eval '
  out=$(env WTS_NAME=render WTS_ROOT="$SANDBOX" WTS_WORKDIR="$SANDBOX" WTS_RESTORE=1 WTS_RESUME=1 WTS_DOC="" WTS_PROMPT="" \
    tmuxinator debug --project-config "$ROOT/share/wts/layouts/default.yml")
  [[ "$out" == *"claude\\ --continue"* && "$out" != *"--name"* ]]'
for l in feature sentry; do
  check "the $l example names the conversation too" eval "
    out=\$(env WTS_NAME=render WTS_ROOT=\"\$SANDBOX\" WTS_WORKDIR=\"\$SANDBOX\" WTS_PROMPT='fix it' \
      tmuxinator debug --project-config \"\$ROOT/examples/layouts/$l.yml\")
    [[ \"\$out\" == *'claude\\ --name\\ render\\ '* ]]"
done
"$WTS" rm evresume -f >/dev/null
cd "$REPO"

# gc --apply is the primary capture path: a merged branch is torn down and must
# leave a row behind, with gc's own verdict on how the work ended.
# The merge is pushed: gc compares against origin/<base>, not the local one, so a
# branch merged only locally is read as squashed and the outcome would not be the
# one under test.
check "gc announces what it will archive, and writes nothing in a dry run" eval '
  env WTS_NO_ATTACH=1 "$WTS" gcarch smoke >/dev/null
  git -C "$WT/gcarch" commit -q --allow-empty -m "work"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff -m merge feature/gcarch
  git -C "$REPO" push -q origin main
  out=$("$WTS" gc --no-fetch)
  [[ "$out" == *"To archive (kept for wts log): 1 session(s)"* ]] \
    && [[ "$(q "select count(*) from archive where session = '"'"'gcarch'"'"'")" == 0 ]]'
check "gc --apply archives the session it tears down" eval '
  "$WTS" gc --apply --no-fetch --no-retro >/dev/null
  [[ "$(q "select count(*) from archive where session = '"'"'gcarch'"'"'")" == 1 ]]'
# gc's own verdict, carried through rather than lost: whether it reads merged or
# squashed depends on how the base moved (its own logic, tested above), but it may
# never arrive as "unknown" — whether the work shipped is the fact a review leans
# on hardest.
check "and carries gc's verdict into the outcome" eval '
  o=$(q "select outcome from archive where session = '"'"'gcarch'"'"'")
  [[ "$o" == merged || "$o" == squashed || "$o" == remote-deleted ]]'
check "the base it was compared against is recorded" eval '
  [[ "$(q "select base from archive where session = '"'"'gcarch'"'"'")" == main ]]'
check "the worktree really is gone" eval '[[ ! -e "$WT/gcarch" ]]'

check "the schema is at version 12" eval '
  [[ "$(sqlite3 -init /dev/null -readonly "$DB" "PRAGMA user_version")" == 12 ]]'

# ─── PR, CI and review state ─────────────────────────────────────────────────
# gh is a stand-in: it answers from fixtures keyed by what it was asked (a
# branch or a URL), and logs every call, so the test can pin that only
# `wts pr --refresh` ever runs it — never the collector, `wts ls` or the
# switcher's list.
export WTS_SMOKE_GHLOG="$SANDBOX/gh.log" WTS_SMOKE_GHDIR="$SANDBOX/ghfix"
mkdir -p "$SANDBOX/ghbin" "$WTS_SMOKE_GHDIR"
cat > "$SANDBOX/ghbin/gh" <<'EOF'
#!/bin/sh
echo "$*" >> "$WTS_SMOKE_GHLOG"
if [ "$1 $2" = "pr list" ]; then
  if [ -n "$WTS_SMOKE_GH_FAIL" ]; then
    [ "$WTS_SMOKE_GH_FAIL" = 1 ] && WTS_SMOKE_GH_FAIL="error connecting to api.github.com"
    echo "$WTS_SMOKE_GH_FAIL" >&2
    exit 1
  fi
  if [ -f "$WTS_SMOKE_GHDIR/pr-list.json" ]; then cat "$WTS_SMOKE_GHDIR/pr-list.json"; else echo '[]'; fi
  exit 0
fi
[ "$1 $2" = "pr view" ] || exit 1
if [ -n "$WTS_SMOKE_GH_FAIL" ]; then
  [ "$WTS_SMOKE_GH_FAIL" = 1 ] && WTS_SMOKE_GH_FAIL="error connecting to api.github.com"
  echo "$WTS_SMOKE_GH_FAIL" >&2
  exit 1
fi
f="$WTS_SMOKE_GHDIR/$(printf %s "$3" | tr -c 'A-Za-z0-9' '_').json"
[ -f "$f" ] && { cat "$f"; exit 0; }
echo "no pull requests found for branch \"$3\"" >&2
exit 1
EOF
chmod +x "$SANDBOX/ghbin/gh"
GHPATH="$SANDBOX/ghbin:$PATH"
fixture() { # <ident> <json>
  print -r -- "$2" > "$WTS_SMOKE_GHDIR/${1//[^A-Za-z0-9]/_}.json"
}
# Cut from origin/main, as wts-fresh does: the sandbox's local main carries
# commits that earlier sections squash-landed upstream, and a branch cut from
# it is, by gc's own test, already squashed.
for s in pr-ok pr-ci pr-chg pr-none pr-link; do
  WTS_NO_ATTACH=1 WTS_BASE_BRANCH=origin/main "$WTS" "$s" smoke >/dev/null 2>&1
done
check "PR sessions created" eval 'in_registry pr-ok && in_registry pr-link'
fixture "$(reg_field pr-ok branch)" '{"number":41,"state":"OPEN","reviewDecision":"APPROVED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}],
  "mergedAt":null,"url":"https://github.com/o/r/pull/41","headRefName":"'"$(reg_field pr-ok branch)"'"}'
fixture "$(reg_field pr-ci branch)" '{"number":42,"state":"OPEN","reviewDecision":"",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
                       {"__typename":"StatusContext","state":"FAILURE"}],
  "mergedAt":null,"url":"https://github.com/o/r/pull/42","headRefName":"'"$(reg_field pr-ci branch)"'"}'
fixture "$(reg_field pr-chg branch)" '{"number":43,"state":"OPEN","reviewDecision":"CHANGES_REQUESTED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}],
  "mergedAt":null,"url":"https://github.com/o/r/pull/43","headRefName":"'"$(reg_field pr-chg branch)"'"}'
# pr-link: the transcript links two PRs, the last one on another repository's
# branch. By branch, gh would answer #45, an old PR of a previous incarnation;
# the link with this branch as its head is #46 — but the LAST link is #47,
# whose head is not this branch, so it is checked and dropped for the branch.
link_branch=$(reg_field pr-link branch)
fixture "$link_branch" '{"number":45,"state":"MERGED","reviewDecision":"","statusCheckRollup":[],
  "mergedAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/45","headRefName":"'"$link_branch"'"}'
fixture "https://github.com/o/tap/pull/47" '{"number":47,"state":"OPEN","reviewDecision":"",
  "statusCheckRollup":[],"mergedAt":null,"url":"https://github.com/o/tap/pull/47","headRefName":"bump"}'
link_dir="$CLAUDE_CONFIG_DIR/projects/${$(reg_field pr-link worktree)//[^a-zA-Z0-9]/-}"
mkdir -p "$link_dir"
print -r -- '{"type":"pr-link","prNumber":47,"prUrl":"https://github.com/o/tap/pull/47"}' > "$link_dir/t.jsonl"

: > "$WTS_SMOKE_GHLOG"
"$WTS" ls >/dev/null 2>&1
"$WTS" status --json >/dev/null 2>&1
PATH="$GHPATH" "$SWITCH" --list >/dev/null 2>&1
check "ls, status and the switcher's list never call gh" eval '[[ ! -s "$WTS_SMOKE_GHLOG" ]]'

# A machine without gh: the system directories, minus gh. Not /usr/bin itself,
# where the Linux runner (and a distribution package) installs it.
NOGH="$SANDBOX/nogh"
mkdir -p "$NOGH"
for f in /usr/bin/*(N*) /bin/*(N*); do
  [[ "${f:t}" == gh || -e "$NOGH/${f:t}" ]] || ln -s "$f" "$NOGH/${f:t}"
done
check "pr --refresh exits 3 without gh" eval '
  PATH="$NOGH" "$WTS" pr --refresh >/dev/null 2>&1; (( $? == 3 ))'
out=$(PATH="$GHPATH" "$WTS" pr --refresh pr-ok pr-ci pr-chg pr-none pr-link 2>&1) || true
check "pr --refresh prints one line per session" eval '
  [[ "$out" == *"pr-ok"*"#41 ✓"* && "$out" == *"pr-ci"*"#42 ✗ci"* && "$out" == *"pr-chg"*"#43 chg"*
     && "$out" == *"pr-none"*"no pull request"* ]]'
check "gh is asked once per session, plus the linked PR" eval '
  (( $(grep -c "^pr view" "$WTS_SMOKE_GHLOG") == 6 ))'
check "a linked PR on another branch is not taken for the session's" eval '
  [[ "$(q "select number from pr_state where session = '"'"'pr-link'"'"'")" == 45 ]]'
check "no PR is an answer, cached as none" eval '
  [[ "$(q "select state || coalesce(number, '"'"'-'"'"') from pr_state where session = '"'"'pr-none'"'"'")" == "none-" ]]'
check "checks and review are normalized" eval '
  [[ "$(q "select checks || '"'"'/'"'"' || review from pr_state where session = '"'"'pr-chg'"'"'")" == "pending/changes_requested" ]]'

# The contract: `pr` is an object or null. A PR gh saw merged sorts and labels
# the session merged; `merged` itself only when its head is the branch's tip
# (below: pr-link's fixture has no head).
check "status --json carries pr" eval '"$WTS" status --json | jq -e "
  (.[] | select(.name == \"pr-ci\") | .pr | .number == 42 and .state == \"open\"
     and .checks == \"fail\" and .review == null and (.refreshed_at | type) == \"number\")
  and (.[] | select(.name == \"pr-none\") | .pr == null)"'
check "pr --refresh --json is versioned" eval '
  PATH="$GHPATH" "$WTS" pr --refresh --json pr-ci | jq -e ".version == 1
    and .sessions[0].name == \"pr-ci\" and .sessions[0].pr.number == 42 and .sessions[0].error == null"'
check "status --fzf field 9 is the PR label" eval '
  "$WTS" status --fzf | awk -F "\037" "\$1 == \"pr-chg\" { print \$9 }" | grep -qx "#43 chg"'
check "a PR gh saw merged reads merged and sorts last" eval '
  "$WTS" status --json | jq -e "last | .name == \"pr-link\" and .pr.state == \"merged\""'
check "the switcher has a PR column" eval '
  l=$("$SWITCH" --list); [[ "$(print -r -- "$l" | sed -n 2p)" == *" PR "* ]] \
    && print -r -- "$l" | grep -q "#42 ✗ci"'
check "the PR column is in the skeleton too, same layout" \
  eval 'diff <("$SWITCH" --list-fast | sed -n 2p) <("$SWITCH" --list | sed -n 2p)'
check "rows with a PR column are padded to the list width" \
  eval 'WTS_SWITCH_COLS=70 "$SWITCH" --list | same_width 70 \
        && WTS_SWITCH_COLS=70 "$SWITCH" --list-fast | same_width 70'
# Captured, not piped into grep -q: the preview goes on printing the pane after
# the match, and under pipefail the closed pipe is the pipeline's status.
check "the preview spells the PR out" eval '
  out=$("$SWITCH" --preview pr-ci pr-ci); [[ "$out" == *"PR #42 open · checks failing"* ]]'
check "a merged session's preview offers ctrl-d" eval '
  out=$("$SWITCH" --preview pr-link pr-link); [[ "$out" == *"merged #45 · ctrl-d to remove"* ]]'

# A repository without a GitHub remote has no PR, it is not failing: as an
# error, gh's reason sat above every preview of the README demo.
check "no GitHub remote reads as no PR, not as an error" eval '
  PATH="$GHPATH" WTS_SMOKE_GH_FAIL="none of the git remotes configured for this repository point to a known GitHub host" \
    "$WTS" pr --refresh pr-none >/dev/null 2>&1 \
  && [[ "$(q "select state || '"'"'|'"'"' || error from pr_state where session = '"'"'pr-none'"'"'")" == "none|" ]]'

# The slow timer: a refresh younger than --if-older is not repeated.
: > "$WTS_SMOKE_GHLOG"
PATH="$GHPATH" "$ROOT/libexec/wts/wts-pr" --refresh --if-older 300 --quiet
check "the timer does not repeat a fresh refresh" eval '[[ ! -s "$WTS_SMOKE_GHLOG" ]]'
q "UPDATE kv SET value = '0' WHERE key = 'pr.refresh_at'"
PATH="$GHPATH" "$ROOT/libexec/wts/wts-pr" --refresh --if-older 300 --quiet
check "the timer refreshes an old one" eval '[[ -s "$WTS_SMOKE_GHLOG" ]]'

# A failure keeps the last good answer and says why, with a non-zero exit.
check "a failing gh exits 1" eval '
  PATH="$GHPATH" WTS_SMOKE_GH_FAIL=1 "$WTS" pr --refresh pr-ci >/dev/null 2>&1; (( $? == 1 ))'
check "and keeps the last answer, with the reason" eval '
  [[ "$(q "select number || '"'"'|'"'"' || error from pr_state where session = '"'"'pr-ci'"'"'")" == "42|error connecting"* ]]'

# Squash merged: the branch's commit lands on origin/main as a different commit
# with the same diff. Ancestry says no; the patch-id test says yes.
SQ_WT=$(reg_field pr-ok worktree)
print squash > "$SQ_WT/SQUASHED"
git -C "$SQ_WT" add SQUASHED
git -C "$SQ_WT" commit -qm "squash me"
sq_clone="$SANDBOX/sq-clone"
git clone -q "$ORIGIN" "$sq_clone"
print squash > "$sq_clone/SQUASHED"
git -C "$sq_clone" add SQUASHED
git -C "$sq_clone" commit -qm "Squash me (#41)"
git -C "$sq_clone" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
check "pr --refresh alone says merged, before any collector pass" eval '
  out=$(PATH="$GHPATH" "$WTS" pr --refresh pr-ok 2>&1); [[ "$out" == "pr-ok  merged  "* ]]'
check "a squash-merged branch reads merged" eval '
  "$WTS" status --json | jq -e ".[] | select(.name == \"pr-ok\") | .merged"'
check "it is labelled merged even though gh said open" eval '
  "$WTS" status --fzf | awk -F "\037" "\$1 == \"pr-ok\" { print \$9 }" | grep -qx merged'
check "merged sessions sort after every live one" eval '
  "$WTS" status --json | jq -e "(map(.merged or .pr.state == \"merged\") | . == sort)"'
check "a commit on top is not merged any more" eval '
  print more >> "$SQ_WT/SQUASHED" && git -C "$SQ_WT" commit -qam more \
  && "$WTS" status --json | jq -e ".[] | select(.name == \"pr-ok\") | .merged == false"'
git -C "$SQ_WT" reset -q --hard HEAD~1

# rm deletes a squash-merged branch without -f, and archives it as squashed.
sq_branch=$(reg_field pr-ok branch)
out=$("$WTS" rm pr-ok </dev/null 2>&1)
check "rm deletes a squash-merged branch without -f" eval '
  [[ "$out" == *"branch $sq_branch deleted (squashed)"* ]] \
  && ! git -C "$REPO" show-ref --verify --quiet "refs/heads/$sq_branch"'
check "and archives it as squashed" eval '
  [[ "$(q "select outcome from archive where session = '"'"'pr-ok'"'"' order by id desc limit 1")" == squashed ]]'
check "the PR rows go with the session" eval '
  [[ "$(q "select count(*) from pr_state where session = '"'"'pr-ok'"'"'")$(q "select count(*) from merge_checks where session = '"'"'pr-ok'"'"'")" == 00 ]]'
# A squash of SEVERAL commits lands as one combined diff, which matches none of
# the branch's patch-ids: #39 and #40 (4 and 3 commits) read merged:false, gc
# left them out and `wts rm -f` archived them abandoned. The content test is a
# merge into the base that would change nothing. The base moves on after the
# squash, so the base's tip is not the squash itself.
sq_land() { # <session>: squash its branch onto origin/main, one commit, then one more
  local b; b=$(reg_field "$1" branch)
  git -C "$sq_clone" fetch -q origin && git -C "$sq_clone" reset -q --hard origin/main
  git -C "$sq_clone" fetch -q "$REPO" "refs/heads/$b"
  git -C "$sq_clone" merge -q --squash FETCH_HEAD >/dev/null 2>&1
  git -C "$sq_clone" commit -qm "$1 (#50)"
  print later > "$sq_clone/LATER-$1"
  git -C "$sq_clone" add "LATER-$1"
  git -C "$sq_clone" commit -qm "unrelated, after the squash"
  git -C "$sq_clone" push -q origin HEAD:main
  git -C "$REPO" fetch -q origin
}
sq_commits() { # <session> <n>: n commits of its own, one file rewritten twice
  local w i; w=$(reg_field "$1" worktree)
  for i in {1..$2}; do
    print "$1 step $i" > "$w/$1-$i"
    print "$1 step $i" >> "$w/$1-notes"
    git -C "$w" add -A && git -C "$w" commit -qm "$1: step $i"
  done
}
sq_merged() { "$WTS" status --json | jq -e --arg n "$1" ".[] | select(.name == \$n) | .merged" >/dev/null }
gc_tears() { "$WTS" gc --no-fetch --json </dev/null | jq -e --arg n "$1" "any(.teardown[]; .session == \$n)" >/dev/null }
for s in sq-multi sq-force sq-pr; do
  WTS_NO_ATTACH=1 WTS_BASE_BRANCH=origin/main "$WTS" "$s" smoke >/dev/null 2>&1
done
sq_commits sq-multi 3
sq_commits sq-force 3
sq_commits sq-pr 2
check "a 3-commit branch is not merged before its squash" eval '! sq_merged sq-multi && ! gc_tears sq-multi'
sq_land sq-multi
sq_land sq-force
check "its patch-ids match nothing in the base" eval '
  [[ "$(git -C "$REPO" cherry origin/main "$(reg_field sq-multi branch)" | grep -c "^+")" == 3 ]]'
check "a 3-commit branch squash-merged reads merged" eval 'sq_merged sq-multi'
check "and gc tears it down" eval 'gc_tears sq-multi'
check "gc says how it landed" eval '
  "$WTS" gc --no-fetch --json </dev/null | jq -e "any(.teardown[]; .session == \"sq-multi\" and (.why | startswith(\"squashed\")))"'
sqm_wt=$(reg_field sq-multi worktree)
print "after the squash" >> "$sqm_wt/sq-multi-notes"
git -C "$sqm_wt" commit -qam "one more, after the squash"
check "one commit after the squash: not merged" eval '! sq_merged sq-multi'
check "and gc leaves it" eval '! gc_tears sq-multi'
git -C "$sqm_wt" reset -q --hard HEAD~1
sqm_branch=$(reg_field sq-multi branch)
out=$("$WTS" rm sq-multi </dev/null 2>&1)
check "rm deletes the squashed branch without -f" eval '
  [[ "$out" == *"branch $sqm_branch deleted (squashed)"* ]]'
check "and archives it as squashed" eval '
  [[ "$(q "select outcome from archive where session = '"'"'sq-multi'"'"' order by id desc limit 1")" == squashed ]]'
"$WTS" rm sq-force -f </dev/null >/dev/null 2>&1
check "rm -f archives a squashed branch as squashed, not abandoned" eval '
  [[ "$(q "select outcome from archive where session = '"'"'sq-force'"'"' order by id desc limit 1")" == squashed ]]'

# The second witness: gh saw the PR merged, at the branch's current tip. Its
# content is nowhere in the local base (not fetched yet, or changed again
# since), so only pr_state can say it.
sqp_wt=$(reg_field sq-pr worktree)
sqp_tip=$(git -C "$sqp_wt" rev-parse HEAD)
fixture "$(reg_field sq-pr branch)" '{"number":51,"state":"MERGED","reviewDecision":"APPROVED",
  "statusCheckRollup":[],"mergedAt":"2026-10-03T00:00:00Z","url":"https://github.com/o/r/pull/51",
  "headRefName":"'"$(reg_field sq-pr branch)"'","headRefOid":"'"$sqp_tip"'"}'
check "not merged before gh says so" eval '! sq_merged sq-pr && ! gc_tears sq-pr'
PATH="$GHPATH" "$WTS" pr --refresh sq-pr >/dev/null 2>&1
check "pr --refresh keeps the PR's head" eval '
  [[ "$(q "select head from pr_state where session = '"'"'sq-pr'"'"'")" == "$sqp_tip" ]]'
check "a PR gh saw merged at the tip reads merged" eval 'sq_merged sq-pr'
check "and gc tears it down" eval 'gc_tears sq-pr'
print "after the merge" >> "$sqp_wt/sq-pr-notes"
git -C "$sqp_wt" commit -qam "one more, after the merge"
check "a commit past the PR's head is not covered" eval '! sq_merged sq-pr && ! gc_tears sq-pr'
"$WTS" rm sq-pr -f </dev/null >/dev/null 2>&1

# After a release. The squash landed, then the base rewrote the very lines it
# added (the CHANGELOG's "## Unreleased" became a version, the entry got its PR
# number): the three-way merge conflicts and the content tests say unmerged.
# Only the pull request still says it merged, and gc now asks gh itself, after
# its fetch — once for the repository, never with --no-fetch.
for s in sq-rel sq-wip; do
  WTS_NO_ATTACH=1 WTS_BASE_BRANCH=origin/main "$WTS" "$s" smoke >/dev/null 2>&1
done
rel_wt=$(reg_field sq-rel worktree)
print -r -- $'# Changelog\n\n## Unreleased\n\n- the release-proof feature\n' > "$rel_wt/RELNOTES"
git -C "$rel_wt" add RELNOTES && git -C "$rel_wt" commit -qm "sq-rel: notes"
sq_commits sq-rel 2
sq_land sq-rel
sed -e 's/^## Unreleased/## 1.0.0/' -e 's/feature$/feature (#52)/' "$sq_clone/RELNOTES" > "$sq_clone/RELNOTES.new"
mv "$sq_clone/RELNOTES.new" "$sq_clone/RELNOTES"
git -C "$sq_clone" commit -qam "Release 1.0.0"
git -C "$sq_clone" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
sq_commits sq-wip 2
rel_tip=$(git -C "$rel_wt" rev-parse HEAD)
wip_tip=$(git -C "$(reg_field sq-wip worktree)" rev-parse HEAD)
check "after a release the content test misses the squash" eval '
  ! git -C "$REPO" merge-tree --write-tree origin/main "$(reg_field sq-rel branch)" >/dev/null 2>&1 \
  && ! gc_tears sq-rel'
# sq-wip: gh lists it merged too, but at an older head — the commit on top is
# real work no PR carried, and it must stay.
print -r -- '[{"number":52,"headRefName":"'"$(reg_field sq-rel branch)"'","headRefOid":"'"$rel_tip"'",
  "mergedAt":"2026-10-03T00:00:00Z","url":"https://github.com/o/r/pull/52"},
 {"number":53,"headRefName":"'"$(reg_field sq-wip branch)"'","headRefOid":"'"$(git -C "$REPO" rev-parse "$wip_tip~1")"'",
  "mergedAt":"2026-10-03T00:00:00Z","url":"https://github.com/o/r/pull/53"}]' > "$WTS_SMOKE_GHDIR/pr-list.json"
: > "$WTS_SMOKE_GHLOG"
PATH="$GHPATH" "$WTS" gc --no-fetch --json </dev/null >/dev/null 2>&1
check "gc --no-fetch never asks gh" eval '[[ ! -s "$WTS_SMOKE_GHLOG" ]]'
plan=$(PATH="$GHPATH" "$WTS" gc --json </dev/null 2>/dev/null)
check "gc asks gh once for the repository, merged PRs only" eval '
  [[ "$(grep -c "^pr list" "$WTS_SMOKE_GHLOG")" == 1 && "$(grep -c . "$WTS_SMOKE_GHLOG")" == 1 ]] \
  && grep -q -- "--state merged" "$WTS_SMOKE_GHLOG"'
check "and tears down the branch whose PR merged at its tip" eval '
  print -r -- "$plan" | jq -e "any(.teardown[]; .session == \"sq-rel\" and (.why | startswith(\"squashed\")))"'
check "a branch with work past its merged PR stays" eval '
  print -r -- "$plan" | jq -e "all(.teardown[]; .session != \"sq-wip\")"'
check "gc wrote what gh said to the session's pr_state" eval '
  [[ "$(q "select state || '"'"'|'"'"' || number || '"'"'|'"'"' || head from pr_state where session = '"'"'sq-rel'"'"'")" == "merged|52|$rel_tip" ]]'
check "and the collector reads it merged too" eval 'sq_merged sq-rel'
check "gc says what it asked" eval '
  out=$(PATH="$GHPATH" "$WTS" gc </dev/null 2>/dev/null); [[ "$out" == *"Pull requests: asked gh about "*" unmerged branch(es), "*" merged at their tip"* ]]'
check "a repository without a GitHub remote says nothing about gh" eval '
  out=$(PATH="$GHPATH" WTS_SMOKE_GH_FAIL="none of the git remotes configured for this repository point to a known GitHub host" \
        "$WTS" gc </dev/null 2>/dev/null)
  [[ "$out" != *"Pull requests"* && "$out" == *"fetch --prune ok"* ]]'
check "a failing gh is named, and gc goes on" eval '
  out=$(PATH="$GHPATH" WTS_SMOKE_GH_FAIL=1 "$WTS" gc </dev/null 2>/dev/null)
  [[ "$out" == *"gh failed (error connecting"* && "$out" == *"Orphan registry"* ]]'
rm -f "$WTS_SMOKE_GHDIR/pr-list.json"
"$WTS" rm sq-rel -f </dev/null >/dev/null 2>&1
"$WTS" rm sq-wip -f </dev/null >/dev/null 2>&1

for s in pr-ci pr-chg pr-none pr-link; do "$WTS" rm "$s" -f </dev/null >/dev/null 2>&1; done

# ─── Agent friendly ──────────────────────────────────────────────────────────
# What wts is like for the Claude agent in a pane: a Bash tool with no terminal
# on stdin. Every command here runs with </dev/null for that reason.

# Things is read from a terminal only, and a refusal is not cached as "absent".
things_kv() { q "SELECT count(*) FROM kv WHERE key = 'things.db'" }
kv_before=$(things_kv)
check "wts-things refuses to read Things without a terminal (exit 3)" eval '
  out=$(env -u WTS_THINGS_DB -u WTS_NO_THINGS "$ROOT/libexec/wts/wts-things" tasks </dev/null 2>&1)
  (( $? == 3 )) && [[ "$out" == *"from a terminal only"* ]]'
check "and caches no verdict for it" eval '[[ "$(things_kv)" == "$kv_before" ]]'

# A person at a terminal does get Things read, through every caller that hides
# stderr. From 1.6.0 the guard tested stderr too, and `wts task ls` reads Things
# with 2>/dev/null: refused for a person as for an agent, without a word, so a
# task completed in Things never left the switcher. Every other check reaches
# Things through a stub or WTS_NO_THINGS, which is why none saw it. So: the real
# guard, the real glob under a HOME of its own, the real probe, on a real tty.
TH_UUID="SmokeThingsGuard1"
TH_DIR="$SANDBOX/thome/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/ThingsData-TEST/Things Database.thingsdatabase"
mkdir -p "$TH_DIR"
sqlite3 -init /dev/null "$TH_DIR/main.sqlite" "
  CREATE TABLE TMTask (uuid TEXT PRIMARY KEY, title TEXT, notes TEXT, status INTEGER,
    stopDate REAL, trashed INTEGER, type INTEGER, area TEXT, creationDate REAL,
    userModificationDate REAL, startDate INTEGER);
  CREATE TABLE TMArea (uuid TEXT PRIMARY KEY, title TEXT);
  CREATE TABLE TMTag (uuid TEXT PRIMARY KEY, title TEXT);
  CREATE TABLE TMTaskTag (tasks TEXT, tags TEXT);
  INSERT INTO TMTask VALUES ('$TH_UUID', 'Guarded things task', '', 3,
    1790000000, 0, 0, NULL, 1780000000, 1790000000, NULL);" >/dev/null
th_kv=$(q "SELECT value FROM kv WHERE key = 'things.db'")
th_had=$(things_kv)
q "INSERT INTO tasks (id, source, title, status, synced_at)
   VALUES ('$TH_UUID', 'things', 'Guarded things task', 'open', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
check "an open Things snapshot is in the switcher" eval '
  out=$("$SWITCH" --list 2>/dev/null); [[ "$out" == *"Guarded things task"* ]]'
# A script, and only its path typed: a typed line past the tty's limit is cut.
print -r -- "#!/bin/zsh -f
unset WTS_THINGS_DB WTS_NO_THINGS WTS_THINGS_FROM_SCRIPT WTS_THINGS_BIN
export PATH='$PATH' HOME='$SANDBOX/thome' XDG_STATE_HOME='$XDG_STATE_HOME'
'$WTS' task ls --all >/dev/null
print -r -- rc=\$?
sqlite3 -init /dev/null '$DB' \"SELECT 'snapshot=' || status FROM tasks WHERE id = '$TH_UUID'\"" > "$SANDBOX/thingsls.sh"
chmod +x "$SANDBOX/thingsls.sh"
tmux new-session -d -s thingsls -x 160 -y 20 -c "$SANDBOX" "zsh -f -i"
tmux send-keys -t "=thingsls:" "$SANDBOX/thingsls.sh" Enter
check "wts task ls at a terminal reads Things through the real guard" pane_contains thingsls "snapshot=completed"
check "and exits 0" pane_contains thingsls "rc=0"
check "and the task completed in Things is completed in wts" eval '
  [[ "$(q "SELECT status FROM tasks WHERE id = '\''$TH_UUID'\''")" == completed ]] &&
  [[ -n "$(q "SELECT completed_at FROM tasks WHERE id = '\''$TH_UUID'\''")" ]]'
check "so it leaves the switcher" eval '
  out=$("$SWITCH" --list 2>/dev/null); [[ "$out" != *"Guarded things task"* ]]'
check "without a terminal, stderr hidden, it is still refused (exit 3)" eval '
  env -u WTS_THINGS_DB -u WTS_NO_THINGS -u WTS_THINGS_FROM_SCRIPT HOME="$SANDBOX/thome" \
    "$ROOT/libexec/wts/wts-things" tasks </dev/null >/dev/null 2>/dev/null
  (( $? == 3 ))'
tmux kill-session -t "=thingsls" 2>/dev/null || true
q "DELETE FROM tasks WHERE id = '$TH_UUID'"
if [[ "$th_had" == 0 ]]; then
  q "DELETE FROM kv WHERE key = 'things.db'"
else
  q "INSERT OR REPLACE INTO kv VALUES ('things.db', '$th_kv')"
fi
check "a task picker without a terminal names what to pass, exit 2" eval '
  out=$(env -u WTS_THINGS_DB "$WTS" task show </dev/null 2>&1)
  [[ "$out" == *"no terminal to pick a task in"*"wts task ls --json"* ]]'
check "so does the document picker" eval '
  out=$("$ROOT/libexec/wts/wts-doc" pick </dev/null 2>&1); (( $? == 2 )) && [[ "$out" == *"pass its slug"* ]]'

# Creation from an agent: detached, and the result as JSON on stdout only.
check "--json creates detached and prints the session" eval '
  out=$("$WTS" agent-a "write the agent docs" smoke --json </dev/null 2>/dev/null)
  print -r -- "$out" | jq -e ".version == 1 and .name == \"agent-a\" and .started == true
                             and .branch == \"feature/agent-a\" and (.worktree | endswith(\"/agent-a\"))"'
check "without a terminal a creation never attaches" eval '
  "$WTS" agent-b smoke </dev/null >/dev/null 2>&1 && has_session agent-b'
check "new --json prints every session it created" eval '
  out=$("$WTS" new -p smoke --json agent-c agent-d </dev/null 2>/dev/null)
  print -r -- "$out" | jq -e "map(.name) == [\"agent-c\", \"agent-d\"]"'
"$WTS" rm agent-c -f >/dev/null 2>&1
"$WTS" rm agent-d -f >/dev/null 2>&1

# JSON for every listing.
AT=$(tt new "Make wts agent friendly")
tt link "$AT" agent-a >/dev/null
check "task ls --json lists the task and its live session" eval '
  "$WTS" task ls --json </dev/null | jq -e --arg t "$AT" \
    ".version == 1 and any(.tasks[]; .id == \$t and .sessions[0].name == \"agent-a\" and .sessions[0].state == \"live\")"'
check "task show --json carries notes, sessions and attempts" eval '
  tt note "$AT" "start with the Things guard" >/dev/null
  "$WTS" task show "$AT" --json </dev/null | jq -e \
    ".title == \"Make wts agent friendly\" and .wts_notes[0].body == \"start with the Things guard\"
     and (.sessions | length) == 1 and (.attempts | type) == \"array\""'
check "doc ls --json is versioned" eval '"$WTS" doc ls --json </dev/null | jq -e ".version == 1 and (.documents | type) == \"array\""'
q "INSERT OR REPLACE INTO briefs VALUES ('agent-a', 'k', 'done: docs drafted' || char(10) || 'next: review', strftime('%s','now') - 120)"
check "brief --cached --json reads the database, no model" eval '
  "$WTS" brief --cached --json agent-a </dev/null | jq -e \
    ".briefs[0].session == \"agent-a\" and (.briefs[0].body | startswith(\"done: docs drafted\")) and .briefs[0].age_s >= 120"'
refute "brief --json alone would call the model: refused" eval '"$WTS" brief --json </dev/null 2>/dev/null'
check "gc --json is the plan" eval '
  "$WTS" gc --no-fetch --json </dev/null | jq -e ".version == 1 and .scope == \"wts\" and (.teardown | type) == \"array\""'
check "gc --json from inside a worktree plans for the repository" eval '
  out=$(cd "$WT/agent-a" && "$WTS" gc --no-fetch --json </dev/null)
  print -r -- "$out" | jq -e --arg r "$REPO" ".repo_root == \$r"'
check "gc --json --apply is refused, exit 2" eval '"$WTS" gc --json --apply </dev/null 2>/dev/null; (( $? == 2 ))'
check "doctor --json says whether wts is ready" eval '
  "$WTS" doctor --json </dev/null | jq -e ".version == 1 and .ready == true and (.checks | length) > 5"'

# The pane an agent runs in, from its own hooks.
pane_a=$(tmux display-message -p -t "=agent-a:" '#{pane_id}')
(cd "$WT/agent-a" && print -r -- '{"session_id":"0123abcd-ef01-2345-6789-abcdef0000aa"}' \
  | TMUX_PANE="$pane_a" "$HOOK" prompt)
check "a hook records its agent's pane" eval '[[ "$(q "SELECT pane FROM agent_panes WHERE session = '\''agent-a'\''")" == "$pane_a" ]]'
# The stand-in agent pane is a shell, so what is sent runs there and shows.
# No record from `claude agents`: agent-a is working, from the prompt above.
print -r -- '[]' > "$WTS_SMOKE_AGENTS"
check "send types into it and submits" eval '"$WTS" send agent-a "echo wts-send-ok" </dev/null >/dev/null'
check "the line ran in the agent pane" pane_shows agent-a wts-send-ok
refute "send to a session whose agent pane is unknown is refused" eval '"$WTS" send agent-b "echo nope" </dev/null 2>/dev/null'
refute "send to no session is refused" eval '"$WTS" send no-such "x" </dev/null 2>/dev/null'

# send looks before it types. A prompt sent to an agent that is asking a
# question was typed into the question, Enter included; one sent after the
# agent had quit ran in the shell its pane had become.
jq -n --arg cwd "$WT/agent-a" '[{kind: "interactive", status: "waiting", waitingFor: "Bash: rm -rf dist", cwd: $cwd, sessionId: "smoke-a"}]' > "$WTS_SMOKE_AGENTS"
check "send to a blocked agent is refused, and names the question" eval '
  out=$("$WTS" send agent-a "echo wts-send-blocked" </dev/null 2>&1); (( $? == 1 )) \
  && [[ "$out" == *"blocked on: Bash: rm -rf dist"*"--answer"* ]]'
check "send --answer types into it" eval '"$WTS" send agent-a --answer "echo wts-answer-ok" </dev/null >/dev/null'
check "the answer ran in the agent pane" pane_shows agent-a wts-answer-ok
refute "and what was refused never reached the pane" eval '
  out=$(tmux capture-pane -pJ -t "=agent-a:"); [[ "$out" == *wts-send-blocked* ]]'
print -r -- '[]' > "$WTS_SMOKE_AGENTS"
refute "send --answer to an agent that is not blocked is refused" eval '"$WTS" send agent-a --answer 1 </dev/null 2>/dev/null'
(cd "$WT/agent-a" && print -r -- '{"session_id":"0123abcd-ef01-2345-6789-abcdef0000aa","reason":"other"}' \
  | TMUX_PANE="$pane_a" "$HOOK" end)
check "send to an agent that has quit is refused: its pane is a shell" eval '
  out=$("$WTS" send agent-a "echo wts-send-dead" </dev/null 2>&1); (( $? == 1 )) \
  && [[ "$out" == *"no agent is reading"*"it is stopped"*"--force"* ]]'
refute "nothing was typed there either" eval '
  out=$(tmux capture-pane -pJ -t "=agent-a:"); [[ "$out" == *wts-send-dead* ]]'
check "send --force types whatever the state" eval '"$WTS" send agent-a --force "echo wts-force-ok" </dev/null >/dev/null'
check "and it shows" pane_shows agent-a wts-force-ok
check "an unknown send option is a usage error, exit 2" eval '"$WTS" send agent-a --loudly x </dev/null 2>/dev/null; (( $? == 2 ))'
(cd "$WT/agent-a" && print -r -- '{"session_id":"0123abcd-ef01-2345-6789-abcdef0000aa"}' \
  | TMUX_PANE="$pane_a" "$HOOK" prompt)

# wait: the states of `wts status --json`.
print -r -- '[]' > "$WTS_SMOKE_AGENTS"
check "wait times out on an agent that never reports, exit 1" eval '
  out=$("$WTS" wait agent-b --until idle --timeout 2 </dev/null 2>/dev/null); (( $? == 1 )) && [[ "$out" == "agent-b "* ]]'
check "and says no agent is known there, rather than to call again" eval '
  err=$("$WTS" wait agent-b --timeout 2 </dev/null 2>&1 >/dev/null); [[ "$err" == *"no agent known in agent-b"* && "$err" != *"call it again"* ]]'
jq -n --arg cwd "$WT/agent-b" '[{kind: "interactive", status: "idle", cwd: $cwd, sessionId: "smoke-b"}]' > "$WTS_SMOKE_AGENTS"
check "wait returns once the agent is idle" eval '
  "$WTS" wait agent-b --timeout 10 --json </dev/null | jq -e ".reached == true and .sessions[0].state == \"idle\" and .sessions[0].stale == false"'
# An agent that claims to work on a pane that no longer moves: the switcher
# says `stuck?`, and a wait that ignored it waited on a frozen agent.
pane_b=$(tmux display-message -p -t "=agent-b:" '#{session_name}:#{window_id}.#{pane_id}')
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
jq -n --arg t "$pane_b" '{sessionId: "smoke-b", tmux: $t}' > "$CLAUDE_CONFIG_DIR/sessions/88888.json"
jq -n --arg cwd "$WT/agent-b" '[{kind: "interactive", status: "busy", cwd: $cwd, sessionId: "smoke-b"}]' > "$WTS_SMOKE_AGENTS"
check "wait returns on a stuck agent, and says so" eval '
  WTS_STALE_AFTER=0 "$WTS" wait agent-b --timeout 10 --json </dev/null \
    | jq -e ".reached == true and .sessions[0].state == \"working\" and .sessions[0].stale == true"'
check "--until working is not fooled by it" eval '
  [[ "$(WTS_STALE_AFTER=0 "$WTS" wait agent-b --until working --timeout 2 </dev/null)" == "agent-b working (stuck?)" ]]'
rm -f "$CLAUDE_CONFIG_DIR/sessions/88888.json"
q "DELETE FROM pane_hashes WHERE agent_session = 'smoke-b'"
refute "wait refuses an unknown state" eval '"$WTS" wait agent-b --until sleeping </dev/null 2>/dev/null'
print -r -- '[]' > "$WTS_SMOKE_AGENTS"

# tail: the agent's last words, from the transcript its hooks named.
proj_a="$CLAUDE_CONFIG_DIR/projects/$(print -r -- "$WT/agent-a" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$proj_a"
{
  print -r -- '{"type":"user","message":{"content":"go"}}'
  print -r -- '{"type":"assistant","timestamp":"2026-10-03T12:00:00Z","message":{"content":[{"type":"text","text":"first answer"}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-10-03T12:01:00Z","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-10-03T12:02:00Z","message":{"content":[{"type":"text","text":"done: the docs are written"}]}}'
} > "$proj_a/0123abcd-ef01-2345-6789-abcdef0000aa.jsonl"
check "tail prints the agent's last message" eval '[[ "$("$WTS" tail agent-a </dev/null)" == *"done: the docs are written"* ]]'
check "tail -n 2 --json skips tool calls" eval '
  "$WTS" tail agent-a -n 2 --json </dev/null | jq -e "[.messages[].text] == [\"first answer\", \"done: the docs are written\"]"'
# The transcript the hooks recorded wins over the one derived from the worktree:
# Claude Code names it in every payload (transcript_path).
mkdir -p "$SANDBOX/elsewhere"
print -r -- '{"type":"assistant","timestamp":"2026-10-03T12:03:00Z","message":{"content":[{"type":"text","text":"from the recorded transcript"}]}}' \
  > "$SANDBOX/elsewhere/0123abcd-ef01-2345-6789-abcdef0000aa.jsonl"
(cd "$WT/agent-a" && print -r -- "{\"session_id\":\"0123abcd-ef01-2345-6789-abcdef0000aa\",\"transcript_path\":\"$SANDBOX/elsewhere/0123abcd-ef01-2345-6789-abcdef0000aa.jsonl\"}" \
  | TMUX_PANE="$pane_a" "$HOOK" stop)
check "a hook records its agent's transcript" eval '
  [[ "$(q "SELECT transcript FROM agent_panes WHERE session = '\''agent-a'\''")" == "$SANDBOX/elsewhere/"*.jsonl ]]'
check "an event without one keeps it" eval '
  (cd "$WT/agent-a" && print -r -- "{\"session_id\":\"0123abcd-ef01-2345-6789-abcdef0000aa\"}" | TMUX_PANE="$pane_a" "$HOOK" prompt)
  [[ "$(q "SELECT transcript FROM agent_panes WHERE session = '\''agent-a'\''")" == "$SANDBOX/elsewhere/"*.jsonl ]]'
check "tail reads the recorded transcript" eval '[[ "$("$WTS" tail agent-a </dev/null)" == *"from the recorded transcript"* ]]'
rm -f "$SANDBOX/elsewhere/0123abcd-ef01-2345-6789-abcdef0000aa.jsonl"
check "and the derived one once that file is gone" eval '[[ "$("$WTS" tail agent-a </dev/null)" == *"done: the docs are written"* ]]'
# A transcript older than the session is a previous session of the same name's:
# the brief and the retrospective never read one, and tail did.
proj_b="$CLAUDE_CONFIG_DIR/projects/$(print -r -- "$WT/agent-b" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$proj_b"
print -r -- '{"type":"assistant","timestamp":"2020-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"words of a previous life"}]}}' > "$proj_b/old.jsonl"
touch -t 202001010000 "$proj_b/old.jsonl"
refute "tail does not read a transcript older than the session" eval '"$WTS" tail agent-b </dev/null 2>/dev/null'
rm -f "$proj_b/old.jsonl"

# Overlap: the first time a session edits a file a sibling has edited.
touch_as() { # <session> <relative path> — the PostToolUse hook, as Claude Code runs it
  (cd "$WT/$1" && print -r -- "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WT/$1/$2\"}}" \
     | env -u TMUX_PANE "$HOOK" touch)
}
check "an edit nobody else made says nothing" eval '[[ -z "$(touch_as agent-a src/api.ts)" ]]'
check "the same file edited next door names the other session" eval '
  touch_as agent-b src/api.ts | jq -e ".hookSpecificOutput.hookEventName == \"PostToolUse\"
    and (.hookSpecificOutput.additionalContext | contains(\"src/api.ts\") and contains(\"agent-a\"))"'
check "once per file" eval '[[ -z "$(touch_as agent-b src/api.ts)" ]]'
check "a file outside the worktree is not recorded" eval '
  (cd "$WT/agent-b" && print -r -- "{\"tool_input\":{\"file_path\":\"/etc/hosts\"}}" | "$HOOK" touch)
  [[ "$(q "SELECT count(*) FROM touches WHERE path LIKE '\''%hosts'\''")" == 0 ]]'
check "SessionStart lists the files both have edited" eval '
  out=$(cd "$WT/agent-b" && env -u TMUX -u TMUX_PANE "$CONTEXT")
  [[ "$out" == *"Files you and another session have both edited:"*"src/api.ts (also: agent-a)"* ]]'
check "and how the task was linked" eval '
  out=$(cd "$WT/agent-a" && env -u TMUX -u TMUX_PANE "$CONTEXT")
  [[ "$out" == *"This session was linked"*"wts task link <id>"* ]]'

# The first editor hears of the second at its next prompt: the warning used to
# reach only the session that edited the file last.
check "the first editor hears that a sibling edited its file too" eval '
  out=$(cd "$WT/agent-a" && print -r -- "{\"session_id\":\"s\"}" | env -u TMUX_PANE "$HOOK" prompt)
  [[ "$out" == *"src/api.ts was edited by session \`agent-b\` too (branch "* ]]'
check "once" eval '
  out=$(cd "$WT/agent-a" && print -r -- "{\"session_id\":\"s\"}" | env -u TMUX_PANE "$HOOK" prompt)
  [[ "$out" != *"src/api.ts"* ]]'

# A subagent's edit runs the hook in the agent's own session, agent_id set.
check "an overlap found at a subagent's edit says so" eval '
  out=$(cd "$WT/agent-b" && print -r -- "{\"tool_name\":\"Edit\",\"agent_id\":\"sub-1\",\"tool_input\":{\"file_path\":\"$WT/agent-b/src/sub.ts\"}}" \
          | env -u TMUX_PANE "$HOOK" touch)
  [[ -z "$out" ]] \
  && out=$(cd "$WT/agent-a" && print -r -- "{\"tool_name\":\"Edit\",\"agent_id\":\"sub-2\",\"tool_input\":{\"file_path\":\"$WT/agent-a/src/sub.ts\"}}" \
          | env -u TMUX_PANE "$HOOK" touch) \
  && print -r -- "$out" | jq -e ".hookSpecificOutput.additionalContext
    | contains(\"src/sub.ts (by a subagent) was edited by session \`agent-b\` too\")"'
# agent-b hears of it at its next turn: told here, so the notes below start clean.
(cd "$WT/agent-b" && print -r -- '{"session_id":"s"}' | env -u TMUX_PANE "$HOOK" prompt >/dev/null)

# Notes reach the other agents at their next turn, or at their next edit.
prompt_as() { (cd "$WT/$1" && print -r -- '{"session_id":"s"}' | env -u TMUX_PANE "$HOOK" prompt) }
note_as() { (cd "$WT/$1" && "$WTS" db set "$2" "$3" >/dev/null 2>&1) }
# A first turn has no previous one to count from: it counts from the session's
# creation. It used to deliver nothing, SessionStart having shown its five
# newest notes — and a note written after SessionStart reached nobody.
q "DELETE FROM agent_events WHERE session = 'agent-b'"
note_as agent-a early "written before agent-b's first turn"
check "a first turn carries the notes left since the session exists" eval '
  [[ "$(prompt_as agent-b)" == *"agent-a/early: written before"* ]]'
check "a turn with nothing new adds nothing" eval '[[ -z "$(prompt_as agent-b)" ]]'
note_as agent-a api-contract "POST /login answers 422 on bad input"
check "the next turn carries the note a sibling left" eval '
  out=$(prompt_as agent-b)
  [[ "$out" == *"new notes"*"agent-a/api-contract: POST /login answers 422"* ]]'
check "and not twice" eval '[[ -z "$(prompt_as agent-b)" ]]'
# Delivery used to compare updated_at with the last turn's start, both to the
# second: a note rewritten in the second it was read was never delivered.
note_as agent-a api-contract "POST /login answers 400 on bad input"
check "a note rewritten in the same second is delivered again" eval '
  [[ "$(prompt_as agent-b)" == *"agent-a/api-contract: POST /login answers 400"* ]]'
q "INSERT OR REPLACE INTO notes (session, key, value, updated_at)
   VALUES ('agent-a', 'raw', 'written by an older wts', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
check "a note written by plain SQL, as an older wts does, is delivered" eval '
  [[ "$(prompt_as agent-b)" == *"agent-a/raw: written by an older wts"* ]]'
q "DELETE FROM agent_events WHERE session = 'agent-b'"
note_as agent-a after-sweep "still delivered"
check "delivery does not depend on the agent's events" eval '
  out=$(prompt_as agent-b); [[ "$out" == *"agent-a/after-sweep: still delivered"* && "$out" != *"agent-a/raw"* ]]'
note_as agent-a mid-turn "heard at the next edit"
check "an edit mid-turn carries a new note" eval '
  touch_as agent-b src/other.ts | jq -e ".hookSpecificOutput.additionalContext | contains(\"agent-a/mid-turn: heard at the next edit\")"'
check "and the next edit, with nothing new, says nothing" eval '[[ -z "$(touch_as agent-b src/other.ts)" ]]'
check "nor the next turn" eval '[[ -z "$(prompt_as agent-b)" ]]'
# Another repository's sessions cannot collide with this one: their notes stay
# out, and are marked so they are not looked at again.
mkdir -p "$SANDBOX/code/elsewhere"
q "INSERT OR REPLACE INTO sessions (name, repo_root, worktree, branch, created_at)
     VALUES ('elsewhere', '$SANDBOX/code/elsewhere', '$SANDBOX/code/elsewhere', 'x', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
   INSERT OR REPLACE INTO notes (session, key, value, updated_at)
     VALUES ('elsewhere', 'foreign', 'another repository', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
check "a note from another repository is never delivered" eval '[[ "$(prompt_as agent-b)" != *foreign* ]]'
q "DELETE FROM sessions WHERE name = 'elsewhere'; DELETE FROM notes WHERE session = 'elsewhere'"
check "WTS_CONTEXT_QUIET silences it" eval '
  note_as agent-a other "x"
  [[ -z "$(cd "$WT/agent-b" && print -r -- "{}" | WTS_CONTEXT_QUIET=1 env -u TMUX_PANE "$HOOK" prompt)" ]]'
check "SessionStart marks what it showed: the next turn does not repeat it" eval '
  (cd "$WT/agent-b" && env -u TMUX -u TMUX_PANE "$CONTEXT" >/dev/null); [[ -z "$(prompt_as agent-b)" ]]'
check "a Stop hook still prints nothing" eval '[[ -z "$(cd "$WT/agent-b" && print -r -- "{}" | "$HOOK" stop)" ]]'
check "seen records who has read what" eval '
  [[ "$(q "SELECT count(*) FROM seen WHERE session = '\''agent-b'\''")" == [1-9]* ]]'
# A note dies with its author: the siblings hear that the session finished,
# how, and what it had said.
note_as agent-b handoff "schema 9 is mine"
check "rm drops the session's touches, pane and marks" eval '
  "$WTS" rm agent-b -f >/dev/null
  [[ "$(q "SELECT count(*) FROM touches WHERE session = '\''agent-b'\''") $(q "SELECT count(*) FROM agent_panes WHERE session = '\''agent-b'\''") $(q "SELECT count(*) FROM seen WHERE session = '\''agent-b'\''")" == "0 0 0" ]]'
# How: agent-b has no commit of its own, so its outcome is whatever rm made of
# an empty branch; the line carries the archive's word for it.
check "a sibling hears that it finished, how, and the notes it left" eval '
  o=$(q "SELECT outcome FROM archive WHERE session = '\''agent-b'\'' ORDER BY id DESC LIMIT 1")
  out=$(prompt_as agent-a)
  [[ -n "$o" && "$out" == *"session \`agent-b\` finished ($o)"*"handoff: schema 9 is mine"* ]]'
check "once" eval '[[ "$(prompt_as agent-a)" != *"agent-b"* ]]'

# setup claude --install: seven hooks, the read-only permissions, the skill.
CS="$SANDBOX/claude-setup"
mkdir -p "$CS"
CLAUDE_CONFIG_DIR="$CS" "$WTS" setup claude --install >/dev/null
CLAUDE_CONFIG_DIR="$CS" "$WTS" setup claude --install >/dev/null
check "setup claude installs the PostToolUse hook on edits, once" eval '
  jq -e "[.hooks.PostToolUse[] | select(.matcher == \"Edit|Write|MultiEdit|NotebookEdit\")] | length == 1" "$CS/settings.json"'
check "and allows the read-only verbs" eval '
  jq -e "(.permissions.allow | index(\"Bash(wts ls:*)\")) and (.permissions.allow | index(\"Bash(wts wait:*)\"))
         and ((.permissions.allow | index(\"Bash(wts rm:*)\")) | not)" "$CS/settings.json"'
check "and writes the skill, its paths filled in" eval '
  grep -q "^name: wts$" "$CS/skills/wts/SKILL.md" && ! grep -q "{{" "$CS/skills/wts/SKILL.md"'
check "doctor finds the seven hooks" eval '[[ "$(CLAUDE_CONFIG_DIR="$CS" "$WTS" doctor)" == *"✓ Claude hooks: all seven"* ]]'
# An install from before the start hook: wts-context alone on SessionStart.
jq '.hooks.SessionStart[].hooks |= map(select(.command | endswith(" start") | not))' "$CS/settings.json" > "$CS/s.tmp" \
  && mv "$CS/s.tmp" "$CS/settings.json"
check "and names the start hook when an older install lacks it" eval '
  out=$(CLAUDE_CONFIG_DIR="$CS" "$WTS" doctor)
  [[ "$out" == *"missing SessionStart (wts-hook start)"* && "$out" != *"from another install"* ]]'
CLAUDE_CONFIG_DIR="$CS" "$WTS" setup claude --install >/dev/null
check "doctor finds the skill" eval '[[ "$(CLAUDE_CONFIG_DIR="$CS" "$WTS" doctor)" == *"✓ Claude skill"* ]]'
print -r -- "my own skill" > "$CS/skills/wts/SKILL.md"
CLAUDE_CONFIG_DIR="$CS" "$WTS" setup claude --install >/dev/null 2>&1
check "a SKILL.md of your own is left alone" eval '[[ "$(<"$CS/skills/wts/SKILL.md")" == "my own skill" ]]'
# ─── Usage: tokens and cost per session ─────────────────────────────────────
# Claude Code repeats a message's usage on every record of it (one per content
# block): message A appears twice, its output growing, and must count once at
# its largest. <synthetic> is Claude Code's placeholder and costs nothing. The
# subagent's file is a transcript of its own, under <session id>/subagents/.
# Opus 5.5: 15 in, 300 out, 1000 written to the 1h cache (2x), 30000 read
# (0.20) -> 0.02006; the Haiku subagent: 100 in, 1000 out -> 0.0051.
{
  print -r -- '{"type":"assistant","message":{"id":"msg_A","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000},"cache_read_input_tokens":10000},"content":[{"type":"thinking"}]}}'
  print -r -- '{"type":"assistant","message":{"id":"msg_A","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000},"cache_read_input_tokens":10000},"content":[{"type":"text","text":"hi"}]}}'
  print -r -- '{"type":"assistant","message":{"id":"msg_B","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":20000},"content":[{"type":"text","text":"ok"}]}}'
  print -r -- '{"type":"assistant","message":{"id":"msg_S","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"No response requested."}]}}'
} > "$proj_a/0123abcd-ef01-2345-6789-abcdef0000bb.jsonl"
mkdir -p "$proj_a/0123abcd-ef01-2345-6789-abcdef0000bb/subagents"
print -r -- '{"type":"assistant","isSidechain":true,"message":{"id":"msg_H","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":1000},"content":[{"type":"text","text":"found it"}]}}' \
  > "$proj_a/0123abcd-ef01-2345-6789-abcdef0000bb/subagents/agent-x.jsonl"

refute "ls and status never read a transcript" eval '
  "$WTS" ls >/dev/null; "$WTS" status --json >/dev/null
  [[ "$(q "SELECT count(*) FROM usage WHERE session = '\''agent-a'\''")" != 0 ]]'
check "wts status --json says usage: null before any count" eval '
  "$WTS" status --json agent-a | jq -e ".[0] | has(\"usage\") and .usage == null"'
"$WTS" brief agent-a </dev/null >/dev/null 2>&1
check "wts brief counts each message once, at its largest" eval '
  [[ "$(q "SELECT sum(output) FROM usage WHERE session = '\''agent-a'\'' AND model = '\''claude-opus-5-5'\''")" == 300 ]]'
check "the synthetic placeholder is left out" eval '
  [[ "$(q "SELECT count(*) FROM usage WHERE model = '\''<synthetic>'\''")" == 0 ]]'
check "a subagent transcript counts, under its own model" eval '
  [[ "$(q "SELECT output FROM usage WHERE session = '\''agent-a'\'' AND model LIKE '\''claude-haiku-4-5%'\''")" == 1000 ]]'
check "status --json carries tokens, cost and the main model" eval '
  "$WTS" status --json agent-a | jq -e ".[0].usage | .output == 1300 and .cache_read == 30000
    and .cost_usd == 0.0252 and .cost_complete and .model == \"claude-opus-5-5\"
    and (.models | length) == 2"'
check "ls --wide adds tokens, cost and model" eval '
  out=$("$WTS" ls --wide)
  [[ "$out" == *TOKENS*COST*MODEL*SUBJECT* && "$(print -r -- "$out" | grep "^agent-a ")" == *"32k"*"\$0.03"*"opus-5-5"* ]]'
check "plain ls does not" eval '[[ "$("$WTS" ls)" != *TOKENS* ]]'
check "status --table --wide is the same table" eval '[[ "$("$WTS" status --table --wide)" == *TOKENS* ]]'
check "the switcher list keeps its 12 fields (usage adds none)" eval '"$WTS" status --fzf | awk -F "\037" "NF != 12 { exit 1 }"'
check "--no-git, what prefix+a and wait poll, has it null" eval '
  "$WTS" status --json --no-git agent-a | jq -e ".[0] | has(\"usage\") and .usage == null"'
q "UPDATE usage SET input = 999 WHERE session = 'agent-a' AND model = 'claude-opus-5-5'"
"$WTS" brief agent-a </dev/null >/dev/null 2>&1
check "an unchanged transcript is not read again" eval '
  [[ "$(q "SELECT input FROM usage WHERE session = '\''agent-a'\'' AND model = '\''claude-opus-5-5'\''")" == 999 ]]'
print -r -- '{"type":"assistant","message":{"id":"msg_C","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[]}}' \
  >> "$proj_a/0123abcd-ef01-2345-6789-abcdef0000bb.jsonl"
"$WTS" brief agent-a </dev/null >/dev/null 2>&1
check "a grown one is, whole" eval '
  [[ "$(q "SELECT input || '\'' '\'' || output FROM usage WHERE session = '\''agent-a'\'' AND model = '\''claude-opus-5-5'\''")" == "16 301" ]]'
q "INSERT INTO usage (session, created_at, transcript, model, output)
   SELECT name, created_at, 'x', 'claude-future-9', 5 FROM sessions WHERE name = 'agent-a'"
check "an unpriced model makes the cost approximate, not wrong" eval '
  "$WTS" status --json agent-a | jq -e ".[0].usage | (.cost_complete | not) and .cost_usd > 0" >/dev/null \
  && [[ "$("$WTS" ls --wide | grep "^agent-a ")" == *"~\$0.03"* ]]'
q "DELETE FROM usage WHERE transcript = 'x'"
check "wts log carries the usage of a live session" eval '
  "$WTS" log --no-things | jq -e "[.work[].sessions[] | select(.name == \"agent-a\")][0].usage.output == 1301"'
q "INSERT OR IGNORE INTO tasks (id, source, title, status, synced_at) VALUES ('t-usage', 'local', 'usage task', 'open', 'x');
   INSERT OR REPLACE INTO task_links VALUES ('agent-a', 't-usage', 'x')"
check "and of the work item, added up over its sessions" eval '
  "$WTS" log --no-things | jq -e "[.work[] | select(.id == \"t-usage\")][0].usage | .output == 1301 and .sessions == 1"'
check "wts task show says what the task cost" eval '
  [[ "$("$WTS" task show t-usage </dev/null)" == *"usage:  32k tokens, \$0.03 at API list prices, over 1 session(s)"* ]]'
check "and task show --json has it" eval '
  "$WTS" task show t-usage --json </dev/null | jq -e ".usage.sessions == 1 and .usage.tokens > 0"'
check "the table is in the schema" eval '[[ "$("$WTS" db schema)" == *"CREATE TABLE usage"* ]]'
# The brief's own call, through the stand-in that answers JSON: its two fields
# are the summary, and its cost a row of its own that the transcript refresh
# (usage_store, which deletes and rewrites a transcript's rows) leaves alone.
BSTUBS="$SANDBOX/brief-stubs"
stub_claude "$BSTUBS" "printf '%s\n' \"\$*\" > '$BSTUBS/args'; printf 'done: wired the stub\nnext: ship it\n'"
q "DELETE FROM briefs WHERE session = 'agent-a'"
check "wts brief reads its two fields from the JSON answer" eval '
  out=$(env PATH="$BSTUBS:$PATH" WTS_NO_LLM= "$WTS" brief agent-a </dev/null 2>&1)
  [[ "$out" == *"done: wired the stub"* && "$out" == *"next: ship it"* \
     && "$(<"$BSTUBS/args")" == *"--json-schema"*"\"next\""* ]]'
check "and records the call under wts:brief" eval '
  [[ "$(q "SELECT messages || '\''|'\'' || cost_usd FROM usage WHERE session = '\''agent-a'\'' AND transcript = '\''wts:brief'\''")" == "1|0.0004" ]]'
print -r -- '{"type":"assistant","message":{"id":"msg_D","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[]}}' \
  >> "$proj_a/0123abcd-ef01-2345-6789-abcdef0000bb.jsonl"
"$WTS" brief agent-a </dev/null >/dev/null 2>&1
check "which a transcript refresh does not drop" eval '
  [[ "$(q "SELECT count(*) FROM usage WHERE session = '\''agent-a'\'' AND transcript = '\''wts:brief'\''")" == 1 \
     && "$(q "SELECT sum(output) FROM usage WHERE session = '\''agent-a'\'' AND model = '\''claude-opus-5-5'\''")" == 302 ]]'
q "DELETE FROM usage WHERE transcript = 'wts:brief'"
"$WTS" rm agent-a -f >/dev/null
check "the usage outlives the session, with its archive row" eval '
  "$WTS" log --no-things --since 2020-01-01 \
    | jq -e "[.work[].sessions[] | select(.name == \"agent-a\" and .state == \"archived\")][0].usage.output == 1302"'
env WTS_NO_ATTACH=1 "$WTS" noarch2 smoke >/dev/null
q "INSERT INTO usage (session, created_at, transcript, model, output)
   SELECT name, created_at, 'y', 'claude-opus-5-5', 7 FROM sessions WHERE name = 'noarch2'"
env WTS_NO_ARCHIVE=1 "$WTS" rm noarch2 -f >/dev/null
check "and goes when there is no archive row to keep it" eval '
  [[ "$(q "SELECT count(*) FROM usage WHERE session = '\''noarch2'\''")" == 0 ]]'
# An existing database, written by a wts before the table: db_init only adds it
# because the schema version moved.
q "DROP TABLE usage; PRAGMA user_version = 5"
check "a database at schema 5 gets the table on the next command" eval '
  "$WTS" ls >/dev/null; [[ "$(q "SELECT count(*) FROM sqlite_master WHERE name = '\''usage'\''")" == 1 ]]'
# Schema 8 is a column on an existing table, which CREATE TABLE IF NOT EXISTS
# never adds: a pr_state from schema 7 gets head, and its rows stay.
q "INSERT OR REPLACE INTO pr_state (session, branch, state) VALUES ('old-pr', 'b', 'open');
   ALTER TABLE pr_state DROP COLUMN head; PRAGMA user_version = 7"
check "a pr_state from schema 7 gets head on the next command" eval '
  "$WTS" ls >/dev/null
  [[ "$(q "SELECT count(*) FROM pragma_table_info('"'"'pr_state'"'"') WHERE name = '"'"'head'"'"'")" == 1
     && "$(q "SELECT state || head FROM pr_state WHERE session = '"'"'old-pr'"'"'")" == open
     && "$(q "PRAGMA user_version")" == 12 ]]'
# Schema 10 is a column on agent_panes: a table from schema 9 gets transcript,
# and its rows stay.
q "INSERT OR REPLACE INTO agent_panes (session, claude_session, pane, at) VALUES ('old-pane', '', '%1', 1);
   ALTER TABLE agent_panes DROP COLUMN transcript; PRAGMA user_version = 9"
check "an agent_panes from schema 9 gets transcript on the next command" eval '
  "$WTS" ls >/dev/null
  [[ "$(q "SELECT count(*) FROM pragma_table_info('"'"'agent_panes'"'"') WHERE name = '"'"'transcript'"'"'")" == 1
     && "$(q "SELECT pane || transcript FROM agent_panes WHERE session = '"'"'old-pane'"'"'")" == "%1"
     && "$(q "PRAGMA user_version")" == 12 ]]'
q "DELETE FROM agent_panes WHERE session = 'old-pane'"
# Schema 11 is a column, usage.cost_usd: a usage table from schema 9 or 10
# gets it, and keeps its rows. From 10 is the case the fast path of db_init
# would skip if the version had not moved.
for from in 9 10; do
  q "INSERT INTO usage (session, created_at, transcript, model, output) VALUES ('old-u', 'c', 't', 'm', 3);
     ALTER TABLE usage DROP COLUMN cost_usd; PRAGMA user_version = $from"
  check "a usage table from schema $from gets cost_usd on the next command" eval '
    "$WTS" ls >/dev/null
    [[ "$(q "SELECT count(*) FROM pragma_table_info('"'"'usage'"'"') WHERE name = '"'"'cost_usd'"'"'")" == 1
       && "$(q "SELECT output FROM usage WHERE session = '"'"'old-u'"'"'")" == 3
       && "$(q "PRAGMA user_version")" == 12 ]]'
  q "DELETE FROM usage WHERE session = 'old-u'"
done
# Schema 12 is one table, agent_gauges: a database at 11 gets it.
q "DROP TABLE agent_gauges; PRAGMA user_version = 11"
check "a database at schema 11 gets agent_gauges on the next command" eval '
  "$WTS" ls >/dev/null
  [[ "$(q "SELECT count(*) FROM sqlite_master WHERE name = '"'"'agent_gauges'"'"'") $(q "PRAGMA user_version")" == "1 12" ]]'
# Schema 9 is one table, seen: the prompt hook may be the first to open a
# database an older wts left at 8, and it must create the table, not fail.
env WTS_NO_ATTACH=1 "$WTS" schema8 smoke >/dev/null
q "DROP TABLE seen; PRAGMA user_version = 8"
check "the prompt hook on a schema-8 database exits 0 and prints nothing" eval '
  out=$(cd "$WT/schema8" && print -r -- "{\"session_id\":\"s\"}" | env -u TMUX_PANE "$HOOK" prompt); (( $? == 0 )) && [[ -z "$out" ]]'
check "and the database has seen afterwards" eval '
  [[ "$(q "SELECT count(*) FROM sqlite_master WHERE name = '"'"'seen'"'"'") $(q "PRAGMA user_version")" == "1 12" ]]'
q "DROP TABLE seen; PRAGMA user_version = 8"
check "a database at schema 8 gets seen on the next command" eval '
  "$WTS" ls >/dev/null; [[ "$(q "SELECT count(*) FROM sqlite_master WHERE name = '"'"'seen'"'"'")" == 1 ]]'
"$WTS" rm schema8 -f >/dev/null 2>&1
# ─── The status line: gauges from Claude Code's statusLine payload ───────────
# A fixture of the payload Claude Code hands its status line command: one row
# in agent_gauges, one printed line, and the keys wts status --json adds.
env WTS_NO_ATTACH=1 "$WTS" gauge-a smoke >/dev/null
env WTS_NO_ATTACH=1 "$WTS" gauge-b smoke >/dev/null
SL_PAYLOAD='{"session_id":"sl-0001","session_name":"gauge-a","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":83.6},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":40.5}}}'
check "statusline prints the session, the model and the context" eval '
  out=$(cd "$WT/gauge-a" && print -r -- "$SL_PAYLOAD" | "$HOOK" statusline); (( $? == 0 )) \
  && [[ "$out" == "wts gauge-a · Opus 5.5 · ctx 84%" ]]'
check "and writes one row into agent_gauges" eval '
  [[ "$(q "SELECT claude_session, model, cost_usd, context_pct, rate_5h, rate_7d FROM agent_gauges WHERE session = '"'"'gauge-a'"'"'")" \
     == "sl-0001|claude-opus-5-5|1.25|83.6|12|40.5" ]]'
check "a refresh overwrites it, one row per conversation" eval '
  (cd "$WT/gauge-a" && print -r -- "$SL_PAYLOAD" | "$HOOK" statusline >/dev/null)
  [[ "$(q "SELECT count(*) FROM agent_gauges WHERE session = '"'"'gauge-a'"'"'")" == 1 ]]'
check "status --json exposes context_pct, rate_limits and cost_reported_usd" eval '
  "$WTS" status --json gauge-a | jq -e ".[0] | .context_pct == 83.6 and .rate_limits.five_hour == 12
    and .rate_limits.seven_day == 40.5 and .cost_reported_usd == 1.25"'
check "and null for a session without a reading" eval '
  "$WTS" status --json gauge-b | jq -e ".[0] | has(\"context_pct\") and .context_pct == null
    and .rate_limits == null and .cost_reported_usd == null"'
check "status --fzf carries the context in field 11" eval '
  [[ "$("$WTS" status --fzf | awk -F "\037" "\$1 == \"gauge-a\" { print \$11 }")" == 84 ]]'
check "ls --wide has a CTX column" eval '
  out=$("$WTS" ls --wide)
  [[ "$out" == *MODEL*CTX*WAITING* && "$(print -r -- "$out" | grep "^gauge-a ")" == *" 84% "* ]]'
check "the switcher marks the row at 80% or more, rows still padded" eval '
  out=$(WTS_SWITCH_COLS=120 "$SWITCH" --list)
  row=$(print -r -- "$out" | grep "^gauge-a ")
  [[ "${row%%$'"'"'\t'"'"'*}" == *"[ctx 84%]"* ]] && print -r -- "$out" | tail -n +3 | awk -F "\t" "length(\$1) != 120 { exit 1 }"'
q "INSERT INTO agent_events (session, claude_session, event, kind, message, at)
   VALUES ('gauge-a', 'sl-0001', 'prompt', '', '', strftime('%s','now'))"
check "the preview header says ctx after the state" eval '
  export WTS_SWITCH_META="$SANDBOX/sl.meta"
  "$SWITCH" --list >/dev/null
  out=$("$SWITCH" --preview gauge-a gauge-a)
  l=("${(@f)out}")
  [[ "${l[1]}" == "working "*" · ctx 84%" ]]'
unset WTS_SWITCH_META
# Who needs you, and the notes not handed yet: gauge-b blocked on a
# permission, then a note of gauge-b that gauge-a has not been told.
q "INSERT INTO agent_events (session, claude_session, event, kind, message, at)
   VALUES ('gauge-b', 's-b', 'notification', 'permission_prompt', 'Bash: rm', strftime('%s','now'))"
q "INSERT OR REPLACE INTO notes VALUES ('gauge-b', 'sl-key', 'a note for the status line', strftime('%Y-%m-%dT%H:%M:%SZ','now'))"
check "and counts the sessions that need you and the unseen notes" eval '
  out=$(cd "$WT/gauge-a" && print -r -- "$SL_PAYLOAD" | "$HOOK" statusline)
  [[ "$out" == "wts gauge-a · Opus 5.5 · ctx 84% · "*" session(s) need you · "*" unseen note(s)" ]]'
check "a note handed at the next prompt is no longer unseen" eval '
  (cd "$WT/gauge-a" && print -r -- "{\"session_id\":\"sl-0001\"}" | env -u TMUX_PANE "$HOOK" prompt >/dev/null)
  out=$(cd "$WT/gauge-a" && print -r -- "$SL_PAYLOAD" | "$HOOK" statusline)
  [[ "$out" == *"need you"* && "$out" != *"unseen note"* ]]'
check "outside a wts session: the model and the context, nothing written" eval '
  n=$(q "SELECT count(*) FROM agent_gauges")
  out=$(cd "$SANDBOX" && print -r -- "${SL_PAYLOAD/gauge-a/elsewhere}" | "$HOOK" statusline)
  [[ "$out" == "Opus 5.5 · ctx 84%" && "$(q "SELECT count(*) FROM agent_gauges")" == "$n" ]]'
check "the session name finds the session when the directory does not" eval '
  out=$(cd "$SANDBOX" && print -r -- "${SL_PAYLOAD/gauge-a/gauge-b}" | "$HOOK" statusline)
  [[ "$out" == "wts gauge-b · "* ]]'
check "a payload that is not JSON exits 0, names the session and writes nothing" eval '
  n=$(q "SELECT count(*) FROM agent_gauges")
  out=$(cd "$WT/gauge-a" && print -r -- "not json" | "$HOOK" statusline); (( $? == 0 )) \
  && [[ "$out" == "wts gauge-a · "*"need you" && "$(q "SELECT count(*) FROM agent_gauges")" == "$n" ]]'
"$WTS" rm gauge-b -f >/dev/null 2>&1
check "rm drops the session's gauges" eval '[[ "$(q "SELECT count(*) FROM agent_gauges WHERE session = '"'"'gauge-b'"'"'")" == 0 ]]'
"$WTS" rm gauge-a -f >/dev/null 2>&1

# setup claude --statusline: opt-in, never over a status line of the user's.
CSL="$SANDBOX/claude-statusline"
mkdir -p "$CSL"
CLAUDE_CONFIG_DIR="$CSL" "$WTS" setup claude --install >/dev/null
check "setup claude --install does not set the status line" eval 'jq -e "has(\"statusLine\") | not" "$CSL/settings.json"'
check "doctor reports it as optional, not a warning" eval '
  [[ "$(CLAUDE_CONFIG_DIR="$CSL" "$WTS" doctor)" == *"✓ Claude status line: not set (optional"* ]]'
check "setup claude --statusline writes it" eval '
  CLAUDE_CONFIG_DIR="$CSL" "$WTS" setup claude --statusline >/dev/null
  jq -e --arg c "$ROOT/libexec/wts/wts-hook statusline" ".statusLine.type == \"command\" and .statusLine.command == \$c
    and (.hooks.Stop | length) == 1" "$CSL/settings.json"'
check "and again over its own" eval 'CLAUDE_CONFIG_DIR="$CSL" "$WTS" setup claude --statusline >/dev/null'
check "doctor finds it" eval '[[ "$(CLAUDE_CONFIG_DIR="$CSL" "$WTS" doctor)" == *"✓ Claude status line: wts'"'"'s"* ]]'
jq '.statusLine = {type: "command", command: "~/bin/my-line.sh"}' "$CSL/settings.json" > "$CSL/s.tmp" && mv "$CSL/s.tmp" "$CSL/settings.json"
cp "$CSL/settings.json" "$CSL/mine.json"
check "--statusline refuses a foreign statusLine, exit 1, and prints both chained" eval '
  err=$(CLAUDE_CONFIG_DIR="$CSL" "$WTS" setup claude --statusline 2>&1 >/dev/null); (( $? == 1 )) \
  && [[ "$err" == *"not wts'"'"'s: left untouched"*"my-line.sh"*"wts-hook statusline"* ]]'
check "and leaves the settings as they were" eval 'cmp -s "$CSL/settings.json" "$CSL/mine.json"'
CLAUDE_CONFIG_DIR="$CSL" "$WTS" setup claude --install >/dev/null
check "--install keeps a status line of your own" eval '[[ "$(jq -r .statusLine.command "$CSL/settings.json")" == "~/bin/my-line.sh" ]]'
check "doctor says it is yours, no warning" eval '
  [[ "$(CLAUDE_CONFIG_DIR="$CSL" "$WTS" doctor)" == *"✓ Claude status line: your own"* ]]'

check "log, retro, doctor, keys, doc, stop and pr are info commands for wts-fresh" eval '
  line=$(grep -E "^  ls\|status\|" "$ROOT/libexec/wts/wts-fresh")
  for c in log retro doctor keys doc stop pr; do [[ "$line" == *"|$c|"* ]] || exit 1; done'

print -r -- "── $passed checks passed"
