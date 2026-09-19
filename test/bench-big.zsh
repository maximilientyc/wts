#!/usr/bin/env zsh
# Benchmark: how wts behaves on a large repository. Same sandbox hygiene as
# test/smoke.zsh (throwaway repo, private tmux server, private state dirs, a
# stand-in `claude`, no model call), but the repository is generated to be big:
# hundreds of thousands of files, thousands of commits and refs, an origin whose
# default branch has moved on, worktrees with uncommitted changes, agents in
# every state, big transcripts, a node_modules and a husk folder.
#
# Usage: zsh test/bench-big.zsh [--tier small|medium|large|xl] [--sessions N]
#                               [--runs N] [--keep] [--out <file>] [--quick]
#
#   --tier      files / commits / branches / commits origin is ahead by:
#                 small   1k   /  200 /  100 /   50    (a minute, sanity check)
#                 medium  20k  / 2000 / 1000 /  500
#                 large   150k / 3000 / 3000 / 2000    (default; ~6 GB on disk)
#                 xl      400k / 3000 / 3000 / 2000    (needs ~15 GB)
#   --sessions  worktrees created through wts (default 8; small: 3)
#   --runs      timed repetitions per command (default 3; the first run after
#               creation is reported apart, as the cold one)
#   --keep      keep the sandbox (printed at the end) for manual poking
#   --out       also write the markdown results there (default: stdout only)
#   --quick     skip the slow sections (gc with fetch, the switcher timeline)
#   --sections  "2 6": only these sections, after the creation (which every
#               section needs)
#
# Env: WTS_BENCH_REPO=<path> replays the battery on an existing repository
# instead of generating one: worktrees go to <repo>-worktrees/ and are removed
# afterwards; nothing else in that repository is written. The origin of that
# repository is fetched by `wts gc` unless --quick.
#
# The numbers are for reading side by side, not as absolutes: every run pays a
# zsh + git + jq startup, macOS fork cost, and whatever the disk cache holds.

set -uo pipefail

ROOT="${0:A:h:h}"
WTS="$ROOT/bin/wts"
HELPERS="$ROOT/libexec/wts"
zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

# ─── Options ─────────────────────────────────────────────────────────────────

TIER="${WTS_BENCH_TIER:-large}"
SESSIONS="${WTS_BENCH_SESSIONS:-}"
RUNS="${WTS_BENCH_RUNS:-3}"
KEEP="${WTS_BENCH_KEEP:-}"
OUT="${WTS_BENCH_OUT:-}"
QUICK=""
SECTIONS="${WTS_BENCH_SECTIONS:-1 2 3 4 5 6 7 8}"
while (( $# )); do
  case "$1" in
    --tier)     TIER="$2"; shift 2 ;;
    --sessions) SESSIONS="$2"; shift 2 ;;
    --runs)     RUNS="$2"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    --out)      OUT="$2"; shift 2 ;;
    --quick)    QUICK=1; shift ;;
    --sections) SECTIONS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) print -u2 "bench-big: unknown option $1"; exit 2 ;;
  esac
done

case "$TIER" in
  small)  FILES=1000   COMMITS=200  BRANCHES=100  BEHIND=50   ;;
  medium) FILES=20000  COMMITS=2000 BRANCHES=1000 BEHIND=500  ;;
  large)  FILES=150000 COMMITS=3000 BRANCHES=3000 BEHIND=2000 ;;
  xl)     FILES=400000 COMMITS=3000 BRANCHES=3000 BEHIND=2000 ;;
  *) print -u2 "bench-big: unknown tier $TIER"; exit 2 ;;
esac
[[ -n "$SESSIONS" ]] || { [[ "$TIER" == small ]] && SESSIONS=3 || SESSIONS=8 }
TAGS=$(( BRANCHES / 6 ))
NODE_MODULES=$(( FILES / 3 ))      # untracked files in one worktree
HUSK_FILES=$(( FILES / 3 ))        # files in a folder left behind by `worktree remove`

# ─── Sandbox (see test/smoke.zsh and CLAUDE.md for every line here) ──────────

# /tmp rather than $TMPDIR: unix socket paths are capped at 104 bytes on macOS.
SANDBOX=$(mktemp -d /tmp/wts-bench.XXXXXX)
SANDBOX=${SANDBOX:A}

# $TMUX first: it wins over TMUX_TMPDIR, and a kill-server would reach the real
# server. The socket dir must exist before the first tmux command for the same
# reason (tmux 3.4+ silently ignores a missing TMUX_TMPDIR).
unset TMUX WTS_LAYOUTS_PATH WTS_BRANCH_PREFIX WTS_BASE_BRANCH WTS_SUBDIR WTS_WORKTREES_BASE
export TMUX_TMPDIR="$SANDBOX/tmux"
export XDG_STATE_HOME="$SANDBOX/state"
export XDG_CONFIG_HOME="$SANDBOX/config"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude"
export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export WTS_NO_LLM=1
export LANG=C LC_ALL=C
mkdir -p "$TMUX_TMPDIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME/wts/layouts" \
  "$CLAUDE_CONFIG_DIR/sessions" "$SANDBOX/bin" "$SANDBOX/shim"
SOCK="$TMUX_TMPDIR/tmux-$UID/default"

REPO=""; WT=""
cleanup() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  # fsmonitor daemons keep the worktrees busy; stop them before the rm.
  if [[ -n "$REPO" && -d "$REPO" ]]; then
    local d
    for d in "$REPO" "$WT"/*(N/); do
      git -C "$d" fsmonitor--daemon stop >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "${WTS_BENCH_REPO:-}" && -n "$REPO" ]]; then
    # Only what this run created in someone else's repository.
    local w
    for w in "$WT"/*(N/); do
      git -C "$REPO" worktree remove --force "$w" >/dev/null 2>&1 || rm -rf "$w"
    done
    git -C "$REPO" worktree prune >/dev/null 2>&1
    git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/feature/bench-*' \
      | xargs -n1 git -C "$REPO" branch -D >/dev/null 2>&1
    rmdir "$WT" 2>/dev/null
  fi
  if [[ -n "$KEEP" ]]; then
    print -u2 -- "sandbox kept: $SANDBOX"
  else
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

git config --global user.name bench
git config --global user.email bench@example.com
git config --global init.defaultBranch main
git config --global gc.auto 0

# Stand-in for Claude Code, as in the smoke test.
export WTS_SMOKE_AGENTS="$SANDBOX/agents.json"
export WTS_BENCH_CLAUDE="$SANDBOX/bin/claude"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/sh
[ "$1" = agents ] && { cat "$WTS_SMOKE_AGENTS" 2>/dev/null || echo '[]'; exit 0; }
exec sleep 3600
EOF
chmod +x "$SANDBOX/bin/claude"
print '[]' > "$WTS_SMOKE_AGENTS"
export PATH="$SANDBOX/bin:$PATH"

# Process-count shims: log the call, then run the real binary. Used only in the
# counting passes, never in the timed ones (each shim costs a /bin/sh start).
export WTS_BENCH_PROCLOG="$SANDBOX/proclog"
for tool in git jq tmux claude curl; do
  real=$(command -v "$tool") || continue
  cat > "$SANDBOX/shim/$tool" <<EOF
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >> "\$WTS_BENCH_PROCLOG"
exec "$real" "\$@"
EOF
  chmod +x "$SANDBOX/shim/$tool"
done

# A layout that starts the stand-in agent, so sessions have a `claude` pane to
# hash and to send keys to. `-f /dev/null` keeps ~/.tmux.conf out.
cat > "$XDG_CONFIG_HOME/wts/layouts/bench.yml" <<'EOF'
# wts: branch_prefix=feature/
name: <%= ENV['WTS_NAME'] %>
root: <%= ENV['WTS_WORKDIR'] %>
tmux_options: -f /dev/null
windows:
  - code:
      panes:
        - <%= ENV["WTS_BENCH_CLAUDE"] %>
EOF

# ─── Results ─────────────────────────────────────────────────────────────────

RESULTS="$SANDBOX/results.md"
: > "$RESULTS"
say() { print -r -- "$@" | tee -a "$RESULTS"; }
section() { say ""; say "## $1"; say ""; }
note() { say "$@"; }

# Table rows: label | cold | median | min | runs
LAST_MED=0
TICK_MED=0
want() { [[ " $SECTIONS " == *" $1 "* ]] }
table_head() { say "| ${1:-command} | cold (s) | median (s) | min (s) | runs |"; say "|---|---:|---:|---:|---:|"; }

# bench <label> <runs> <cmd...>: runs the command, output discarded, and prints
# one row. The first run is the cold one (right after whatever changed the
# state); the median and min are over all runs.
bench() {
  local label="$1" runs="$2"; shift 2
  local -a ts
  local t0 t1 i
  for (( i = 1; i <= runs; i++ )); do
    t0=$EPOCHREALTIME
    "$@" >/dev/null 2>&1
    t1=$EPOCHREALTIME
    ts+=( $(printf "%.4f" $(( t1 - t0 ))) )
  done
  local sorted cold med mn
  sorted=( ${(n)ts} )
  cold=${ts[1]}
  mn=${sorted[1]}
  med=${sorted[$(( (runs + 1) / 2 ))]}
  LAST_MED=$med
  say "$(printf '| %s | %.3f | %.3f | %.3f | %d |' "$label" "$cold" "$med" "$mn" "$runs")"
}

# count <label> <cmd...>: one run with the shims in front of PATH, prints how
# many git / jq / tmux / claude / curl processes it spawned.
count() {
  local label="$1"; shift
  : > "$WTS_BENCH_PROCLOG"
  PATH="$SANDBOX/shim:$PATH" "$@" >/dev/null 2>&1
  local g j t c u total
  g=$(grep -c '^git ' "$WTS_BENCH_PROCLOG"); j=$(grep -c '^jq ' "$WTS_BENCH_PROCLOG")
  t=$(grep -c '^tmux ' "$WTS_BENCH_PROCLOG"); c=$(grep -c '^claude ' "$WTS_BENCH_PROCLOG")
  u=$(grep -c '^curl ' "$WTS_BENCH_PROCLOG")
  total=$(( g + j + t + c + u ))
  say "| $label | $g | $j | $t | $c | $u | $total |"
}
count_head() { say "| command | git | jq | tmux | claude | curl | total |"; say "|---|---:|---:|---:|---:|---:|---:|"; }

# Top git subcommands of the last counting pass.
top_git() {
  say ""
  say '```'
  awk '$1 == "git" { for (i = 2; i <= NF; i++) if ($i !~ /^-C$/ && $i !~ /^\// && $i !~ /^--no-optional-locks$/) { print $i; break } }' \
    "$WTS_BENCH_PROCLOG" | sort | uniq -c | sort -rn | head -${1:-8} | tee -a "$RESULTS"
  say '```'
}

elapsed() { printf '%.1f' $(( EPOCHREALTIME - $1 )) }

# ─── Repository ──────────────────────────────────────────────────────────────

# Generator: a git fast-import stream. Files under src/dNNN/sNN/fNNN.txt, one
# initial commit, then $commits commits each rewriting a handful of files,
# $branches topic branches (half at an ancestor of main = merged by ancestry,
# half with one commit of their own = the squash-detection path of `wts gc`),
# and $tags tags. "extend" mode appends $commits to an existing main instead.
cat > "$SANDBOX/gen.pl" <<'EOF'
use strict; use warnings;
my ($mode, $files, $commits, $branches, $tags, $seed) = @ARGV;
srand($seed);
my $t = 1700000000;
my @paths;
if ($mode eq 'init') {
  my $per_dir = 200;
  for my $i (0 .. $files - 1) {
    my $d = int($i / $per_dir); my $s = int(($i % $per_dir) / 10); my $f = $i % 10;
    push @paths, sprintf('src/d%04d/s%02d/f%02d.txt', $d, $s, $f);
  }
  print "commit refs/heads/main\nmark :1\ncommitter bench <bench\@example.com> $t +0000\n";
  print "data 4\ninit\n";
  my $gi = ".DS_Store\nnode_modules/\ndist/\n";
  print "M 100644 inline .gitignore\ndata ", length($gi), "\n$gi";
  for my $p (@paths) {
    my $c = "$p\n" . ("line of content number N in this file\n" x 6);
    print "M 100644 inline $p\ndata ", length($c), "\n$c";
  }
  print "\n";
} else {
  # extend: the paths are the same shape, main already exists.
  my $per_dir = 200;
  for my $i (0 .. $files - 1) {
    my $d = int($i / $per_dir); my $s = int(($i % $per_dir) / 10); my $f = $i % 10;
    push @paths, sprintf('src/d%04d/s%02d/f%02d.txt', $d, $s, $f);
  }
}
my $mark = 1;
my $first = $mode eq 'init' ? 2 : 1;
for my $n ($first .. $commits + ($mode eq 'init' ? 1 : 0)) {
  $t += 60;
  print "commit refs/heads/main\nmark :$n\ncommitter bench <bench\@example.com> $t +0000\n";
  my $msg = "commit $n ($mode)\n";
  print "data ", length($msg), "\n$msg";
  print "from refs/heads/main^0\n" if $mode eq 'extend' && $n == 1;
  for (1 .. 5) {
    my $p = $paths[int(rand(@paths))];
    my $c = "$p\nrevision $n\n" . ("line of content number N in this file\n" x 6);
    print "M 100644 inline $p\ndata ", length($c), "\n$c";
  }
  print "\n";
  $mark = $n;
}
if ($mode eq 'init') {
  for my $b (1 .. $branches) {
    my $from = 1 + int(rand($mark));
    if ($b % 2) {
      print "reset refs/heads/topic/b$b\nfrom :$from\n\n";
    } else {
      $t += 60;
      print "commit refs/heads/topic/b$b\ncommitter bench <bench\@example.com> $t +0000\n";
      my $msg = "topic b$b\n";
      print "data ", length($msg), "\n$msg", "from :$from\n";
      my $p = $paths[int(rand(@paths))];
      my $c = "$p\ntopic b$b\n" . ("line of content number N in this file\n" x 6);
      print "M 100644 inline $p\ndata ", length($c), "\n$c\n";
    }
  }
  for my $v (1 .. $tags) {
    print "reset refs/tags/v$v\nfrom :", 1 + int(rand($mark)), "\n\n";
  }
}
EOF

# Many small files, fast: perl writes them directly.
make_files() { # <dir> <count>
  mkdir -p "$1"
  perl -e '
    my ($dir, $n) = @ARGV;
    for my $i (0 .. $n - 1) {
      my $d = "$dir/pkg" . int($i / 500);
      mkdir $d unless -d $d;
      open my $fh, ">", "$d/f$i.js" or die; print $fh "module.exports = $i;\n"; close $fh;
    }' "$1" "$2"
}

T_START=$EPOCHREALTIME
say "# wts bench — tier $TIER"
say ""
say "- machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
say "- git $(git --version | awk '{print $3}'), tmux $(tmux -V | awk '{print $2}'), fzf $(fzf --version | awk '{print $1}'), jq $(jq --version | sed 's/jq-//'), tmuxinator $(tmuxinator version 2>/dev/null | awk '{print $2}'), zsh $ZSH_VERSION"
say "- wts $("$WTS" --version | awk '{print $2}') from $ROOT"

if [[ -n "${WTS_BENCH_REPO:-}" ]]; then
  REPO=${WTS_BENCH_REPO:A}
  WT="$(dirname "$REPO")/$(basename "$REPO")-worktrees"
  say "- repository: $REPO (existing), $(git -C "$REPO" ls-files | wc -l | tr -d ' ') tracked files, $(git -C "$REPO" for-each-ref | wc -l | tr -d ' ') refs"
else
  REPO="$SANDBOX/code/mono"
  WT="$SANDBOX/code/mono-worktrees"
  ORIGIN="$SANDBOX/code/origin.git"
  mkdir -p "$REPO"
  t0=$EPOCHREALTIME
  git -C "$REPO" init -q
  perl "$SANDBOX/gen.pl" init "$FILES" "$COMMITS" "$BRANCHES" "$TAGS" 42 \
    | git -C "$REPO" fast-import --quiet
  git -C "$REPO" checkout -q main
  git clone -q --bare "$REPO" "$ORIGIN"
  # origin/main moves on by $BEHIND commits: the "base moved" case wts gc and the
  # delta column are about. The local main stays where it is, as on a laptop.
  perl "$SANDBOX/gen.pl" extend "$FILES" "$BEHIND" 0 0 43 \
    | git -C "$ORIGIN" fast-import --quiet
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" fetch -q origin
  git -C "$REPO" branch -q --set-upstream-to=origin/main main
  git -C "$REPO" remote set-head origin main
  # Half of the topic branches track a remote branch that is gone (the
  # `[gone]` orphan category), the other half never had one.
  git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/topic/ \
    | awk 'NR % 2 == 0' | head -$(( BRANCHES / 4 )) \
    | xargs -I{} git -C "$REPO" config "branch.{}.remote" origin
  say "- repository: generated in $(elapsed $t0) s — $FILES files, $COMMITS commits, $BRANCHES topic branches, $TAGS tags, origin/main $BEHIND commits ahead of main"
  say "- .git: $(du -sh "$REPO/.git" | cut -f1), checkout: $(du -sh "$REPO" | cut -f1)"
fi
cd "$REPO"

# ─── 1. Creation ─────────────────────────────────────────────────────────────

section "1. Creating a session"
note "Baseline is a bare \`git worktree add\`; \`wts <name>\` adds the name checks, the registry write and tmuxinator. \`wts \"<phrase>\"\` (WTS_NO_LLM: local slug) adds the uniqueness loop and the \`ls-remote\` against origin."
say ""
table_head "creation"

t0=$EPOCHREALTIME
git -C "$REPO" worktree add -q "$WT/baseline" -b feature/baseline main
say "$(printf '| %s | %.3f | - | - | 1 |' 'git worktree add (baseline)' $(( EPOCHREALTIME - t0 )))"
git -C "$REPO" worktree remove --force "$WT/baseline"; git -C "$REPO" branch -qD feature/baseline

integer n
for (( n = 1; n <= SESSIONS; n++ )); do
  t0=$EPOCHREALTIME
  WTS_NO_ATTACH=1 "$WTS" "bench-$n" bench >/dev/null 2>&1 </dev/null \
    || { print -u2 "bench-big: wts bench-$n failed"; exit 1 }
  (( n <= 2 )) && say "$(printf '| %s | %.3f | - | - | 1 |' "wts bench-$n bench" $(( EPOCHREALTIME - t0 )))"
done
# A phrase whose slug is already taken twice: the uniqueness loop.
WTS_NO_ATTACH=1 "$WTS" rate-limit bench >/dev/null 2>&1 </dev/null
WTS_NO_ATTACH=1 "$WTS" rate-limit-2 bench >/dev/null 2>&1 </dev/null
t0=$EPOCHREALTIME
WTS_NO_ATTACH=1 "$WTS" "rate limit the api" bench >/dev/null 2>&1 </dev/null
say "$(printf '| %s | %.3f | - | - | 1 |' 'wts "<phrase>" (slug taken twice)' $(( EPOCHREALTIME - t0 )))"
for s in rate-limit rate-limit-2 rate-limit-3; do "$WTS" rm "$s" -f >/dev/null 2>&1 </dev/null; done

say ""
count_head
count 'wts bench-x bench (name given)' env WTS_NO_ATTACH=1 "$WTS" bench-x bench
"$WTS" rm bench-x -f >/dev/null 2>&1 </dev/null
top_git 6

# Make the sessions look like work in progress: two commits, three modified
# files, two untracked ones; plus an agent per session, in every state.
say ""
say "Sessions: $SESSIONS, each with 2 commits, 3 modified and 2 untracked files; agents blocked/working/idle in rotation."
agents='[]'
for (( n = 1; n <= SESSIONS; n++ )); do
  w="$WT/bench-$n"
  for f in src/d0000/s00/f00.txt src/d0000/s01/f01.txt; do print "change $n" >> "$w/$f"; done
  git -C "$w" commit -qam "bench-$n: one"
  print "change $n" >> "$w/src/d0000/s02/f02.txt"
  git -C "$w" commit -qam "bench-$n: two"
  for f in src/d0000/s03/f03.txt src/d0000/s04/f04.txt src/d0000/s05/f05.txt; do print "wip $n" >> "$w/$f"; done
  print "new" > "$w/NOTES-$n.md"; print "new" > "$w/src/scratch-$n.txt"
  case $(( n % 3 )) in
    1) st='{"kind":"interactive","status":"waiting"}' ;;
    2) st='{"kind":"interactive","status":"busy"}' ;;
    0) st='{"kind":"interactive","status":"idle"}' ;;
  esac
  pane=$(tmux list-panes -t "=bench-$n" -F '#{session_name}:#{window_id}.#{pane_id}' | head -1)
  agents=$(print -r -- "$agents" | jq -c --arg cwd "$w" --arg sid "sid-bench-$n" --argjson st "$st" \
    '. + [$st + {cwd: $cwd, sessionId: $sid, name: ("agent " + $sid)}]')
  jq -nc --arg sid "sid-bench-$n" --arg tmux "$pane" '{sessionId: $sid, tmux: $tmux, name: "bench"}' \
    > "$CLAUDE_CONFIG_DIR/sessions/$(( 1000 + n )).json"
done
print -r -- "$agents" > "$WTS_SMOKE_AGENTS"

# node_modules (ignored) in bench-1, an untracked build tree (not ignored) in
# bench-2, a husk folder next to the worktrees.
make_files "$WT/bench-1/node_modules" "$NODE_MODULES"
make_files "$WT/bench-2/build" "$NODE_MODULES"
mkdir -p "$WT/old-husk"; make_files "$WT/old-husk/node_modules" "$HUSK_FILES"
say "bench-1 has an ignored node_modules/ of $NODE_MODULES files, bench-2 an untracked build/ of $NODE_MODULES files, and $WT/old-husk is a husk of $HUSK_FILES files."

# ─── 2. The collector ────────────────────────────────────────────────────────
if want 2; then

section "2. Listing: wts ls, wts status, the switcher list"
note "Everything below runs the collector (\`libexec/wts/wts-status\`) once: \`wts ls\`, \`wts status\`, \`prefix+a\`, every switcher tick, \`wts gc\`, \`wts brief\`."
say ""
table_head "command ($SESSIONS sessions)"
bench 'wts ls' "$RUNS" "$WTS" ls
bench 'wts status --json' "$RUNS" "$WTS" status --json
bench 'wts-status --fzf (one tick of the switcher)' "$RUNS" "$HELPERS/wts-status" --fzf
bench 'wts-switch --list (tick incl. formatting)' "$RUNS" "$HELPERS/wts-switch" --list
TICK_MED=$LAST_MED
bench 'wts-switch --list-fast (skeleton, first paint)' "$RUNS" "$HELPERS/wts-switch" --list-fast
bench 'wts-switch --next (prefix+a)' "$RUNS" "$HELPERS/wts-switch" --next
bench 'git worktree list --porcelain (one TAB completion)' "$RUNS" git worktree list --porcelain

say ""
count_head
count "wts ls ($SESSIONS sessions)" "$WTS" ls
top_git 8

# Per-worktree cost of what the collector runs, on one ordinary worktree, the
# one with the ignored node_modules and the one with the untracked build tree.
say ""
note "What the collector runs per worktree (\`wts-status:177-186\`), with the collector's own \`GIT_OPTIONAL_LOCKS=0\`:"
say ""
table_head "per-worktree git call"
export GIT_OPTIONAL_LOCKS=0
bench 'status --porcelain (bench-3, plain)' "$RUNS" git -C "$WT/bench-3" status --porcelain
bench 'status --porcelain (bench-1, ignored node_modules)' "$RUNS" git -C "$WT/bench-1" status --porcelain
bench 'status --porcelain (bench-2, untracked build/)' "$RUNS" git -C "$WT/bench-2" status --porcelain
bench 'rev-list --left-right --count origin/main...HEAD' "$RUNS" git -C "$WT/bench-3" rev-list --left-right --count origin/main...HEAD
bench 'diff --shortstat origin/main...HEAD' "$RUNS" git -C "$WT/bench-3" diff --shortstat origin/main...HEAD
bench 'branch --merged origin/main (all local refs)' "$RUNS" git -C "$REPO" branch --merged origin/main --format '%(refname:short)'
unset GIT_OPTIONAL_LOCKS

# How much of a tick is git, and how much is everything else (jq, tmux, zsh)?
t_git=0
for (( n = 1; n <= SESSIONS; n++ )); do
  w="$WT/bench-$n"; t0=$EPOCHREALTIME
  GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain >/dev/null 2>&1
  GIT_OPTIONAL_LOCKS=0 git -C "$w" rev-list --left-right --count origin/main...HEAD >/dev/null 2>&1
  GIT_OPTIONAL_LOCKS=0 git -C "$w" diff --shortstat origin/main...HEAD >/dev/null 2>&1
  (( t_git += EPOCHREALTIME - t0 ))
done
say ""
say "$(printf 'Sum of the three git calls over %d worktrees: %.3f s; a full tick: %.3f s. The rest is process overhead (jq, tmux, zsh, shasum).' "$SESSIONS" "$t_git" "$TICK_MED")"

fi

# ─── 3. A/B: the same information, cheaper ───────────────────────────────────
if want 3; then

section "3. A/B: alternatives measured on the same worktrees"
note "Direct git calls, no wts code changed. Each row is a candidate for a fix, with its price."
say ""
table_head "variant"
w="$WT/bench-3"
bench 'status --porcelain, GIT_OPTIONAL_LOCKS=0 (never warms)' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain
bench 'status --porcelain, locks allowed (index refreshed)' "$RUNS" git -C "$w" status --porcelain
bench 'status --porcelain --untracked-files=no' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain --untracked-files=no
bench 'status --porcelain=v2 --branch (ahead/behind inside)' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain=v2 --branch
bench 'diff-index --quiet HEAD; ls-files -o --exclude-standard (dirty, no stat)' "$RUNS" env GIT_OPTIONAL_LOCKS=0 sh -c "git -C '$w' diff-index --name-only HEAD; git -C '$w' ls-files -o --exclude-standard --directory"
mb=$(git -C "$w" merge-base origin/main HEAD)
bench 'merge-base once + diff --shortstat <mb> HEAD' "$RUNS" sh -c "git -C '$w' diff --shortstat $mb HEAD"
bench 'diff --numstat <mb> HEAD | awk (no --shortstat rename pass)' "$RUNS" sh -c "git -C '$w' diff --numstat $mb HEAD | awk '{a+=\$1;r+=\$2}END{print a,r}'"
bench 'rev-list --count <mb>..HEAD (ahead only)' "$RUNS" git -C "$w" rev-list --count "$mb..HEAD"
bench 'for-each-ref refs/heads (no %(upstream:track))' "$RUNS" git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/
bench 'for-each-ref refs/heads with %(upstream:track) (gc:151)' "$RUNS" git -C "$REPO" for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/

say ""
note "untrackedCache and fsmonitor (repository settings, not wts): the same \`git status\` with both on. fsmonitor is git's built-in daemon (macOS, git ≥ 2.37); the first call starts it."
say ""
table_head "status --porcelain on bench-3"
git -C "$REPO" config core.untrackedCache true
bench 'untrackedCache=true, GIT_OPTIONAL_LOCKS=0' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain
bench 'untrackedCache=true, locks allowed' "$RUNS" git -C "$w" status --porcelain
git -C "$REPO" config core.fsmonitor true
git -C "$w" status --porcelain >/dev/null 2>&1; sleep 1   # daemon start + first crawl
bench 'fsmonitor=true, GIT_OPTIONAL_LOCKS=0' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain
bench 'fsmonitor=true, locks allowed' "$RUNS" git -C "$w" status --porcelain
bench 'fsmonitor=true, bench-2 untracked build/' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$WT/bench-2" status --porcelain
say ""
table_head "collector with fsmonitor + untrackedCache on"
for (( n = 1; n <= SESSIONS; n++ )); do git -C "$WT/bench-$n" status --porcelain >/dev/null 2>&1; done
bench 'wts ls (fsmonitor on, locks forbidden by wts)' "$RUNS" "$WTS" ls
bench 'wts ls (fsmonitor on, GIT_OPTIONAL_LOCKS unset in wts-status)' "$RUNS" env WTS_BENCH_ALLOW_LOCKS=1 sh -c "sed 's/^export GIT_OPTIONAL_LOCKS=0/: allow locks/' '$HELPERS/wts-status' > '$SANDBOX/wts-status-locks'; chmod +x '$SANDBOX/wts-status-locks'; cd '$REPO'; '$SANDBOX/wts-status-locks' --table"
git -C "$REPO" config core.fsmonitor false
git -C "$REPO" config core.untrackedCache false
for d in "$REPO" "$WT"/bench-*(N/); do git -C "$d" fsmonitor--daemon stop >/dev/null 2>&1; done

say ""
note "Parallel collection: the three git calls per worktree, sequential vs all worktrees at once (\`&\`/\`wait\`), on $SESSIONS worktrees."
say ""
table_head "collection"
collect_seq() { local n; for (( n = 1; n <= SESSIONS; n++ )); do
  git -C "$WT/bench-$n" status --porcelain; git -C "$WT/bench-$n" rev-list --left-right --count origin/main...HEAD; git -C "$WT/bench-$n" diff --shortstat origin/main...HEAD; done }
collect_par() { local n; for (( n = 1; n <= SESSIONS; n++ )); do
  ( git -C "$WT/bench-$n" status --porcelain; git -C "$WT/bench-$n" rev-list --left-right --count origin/main...HEAD; git -C "$WT/bench-$n" diff --shortstat origin/main...HEAD ) & done; wait }
bench 'sequential' "$RUNS" env GIT_OPTIONAL_LOCKS=0 zsh -c "$(typeset -f collect_seq); SESSIONS=$SESSIONS; WT='$WT'; collect_seq"
bench 'parallel (one subshell per worktree)' "$RUNS" env GIT_OPTIONAL_LOCKS=0 zsh -c "$(typeset -f collect_par); SESSIONS=$SESSIONS; WT='$WT'; collect_par"

say ""
note "jq: one process per question (the collector's ~6 per session + one per worktree over the agents array) vs one process for the whole pass."
say ""
table_head "jq"
jq_many() { local n a; for (( n = 1; n <= SESSIONS; n++ )); do
  a=$(print -r -- "$agents" | jq -c --arg wt "$WT/bench-$n" 'map(select(.cwd == $wt)) | first // null')
  print -r -- "$a" | jq -r '.status'; print -r -- "$a" | jq -c '.waitingFor'; print -r -- "$a" | jq -c '.name'; print -r -- "$a" | jq -c '.sessionId'; print -r -- "$a" | jq -r '.sessionId'
  jq -nc --arg n "bench-$n" --arg s "$a" '{name: $n, agent: $s}'; done }
jq_one() { print -r -- "$agents" | jq -c --arg wt "$WT" '[.[] | select(.cwd | startswith($wt)) | {name: .cwd, status, waitingFor, name, sessionId}]' }
bench "$(( SESSIONS * 7 )) jq processes" "$RUNS" zsh -c "$(typeset -f jq_many); SESSIONS=$SESSIONS; WT='$WT'; agents='$agents'; jq_many"
bench '1 jq process' "$RUNS" zsh -c "$(typeset -f jq_one); WT='$WT'; agents='$agents'; jq_one"

say ""
note "Switcher preview per cursor move: \`capture-pane -e -S -2000\` (wts-switch:370) vs the visible screen only."
say ""
table_head "preview"
pane=$(tmux list-panes -t "=bench-1" -F '#{pane_id}' | head -1)
bench 'wts-switch --preview bench-1 <pane> (zsh start + capture)' "$RUNS" "$HELPERS/wts-switch" --preview "$pane" bench-1
bench 'tmux capture-pane -p -e -S -2000' "$RUNS" tmux capture-pane -p -e -S -2000 -t "$pane"
bench 'tmux capture-pane -p -e -S -100' "$RUNS" tmux capture-pane -p -e -S -100 -t "$pane"
bench 'wts-switch --fit bench-1 <pane> (zsh start + display-message)' "$RUNS" "$HELPERS/wts-switch" --fit "$pane" bench-1
bench 'zsh -c exit (interpreter floor)' "$RUNS" zsh -c exit

fi

# ─── 4. gc ───────────────────────────────────────────────────────────────────
if want 4; then

section "4. wts gc"
note "Dry run. \`--no-fetch\` isolates the analysis (for-each-ref with upstream tracking, branch --merged, \`git cherry\` per local branch, the collector, \`du\` on the husk, \`lsof\` on index.lock candidates); the plain form adds \`fetch --all --prune\` against the local bare origin, i.e. the cheapest remote there is."
say ""
table_head "gc ($BRANCHES topic branches, origin/main $BEHIND ahead)"
# gc is linear in the number of local branches (minutes at 3000): one run
# there, and the fetch measured on its own rather than through a second gc.
if (( BRANCHES > 1000 )); then
  bench 'wts gc --no-fetch (dry run)' 1 "$WTS" gc --no-fetch
  gc_med=$LAST_MED
  bench 'git fetch --all --prune (what plain gc adds, local origin)' 1 git -C "$REPO" fetch --all --prune --quiet
  say ""
  say "$(printf 'Per local branch: %.2f s.' $(( gc_med / BRANCHES )))"
else
  bench 'wts gc --no-fetch (dry run)' "$RUNS" "$WTS" gc --no-fetch
  [[ -z "$QUICK" ]] && bench 'wts gc (dry run, with fetch)' "$RUNS" "$WTS" gc
  say ""
  count_head
  count 'wts gc --no-fetch' "$WTS" gc --no-fetch
  top_git 8
fi

say ""
note "A/B on the squash detection: \`git cherry origin/main <b>\` computes a patch-id for every commit on both sides since the merge-base. Branches cut deep in history pay the whole base."
say ""
table_head "one branch"
deep=$(git -C "$REPO" for-each-ref --format='%(refname:short) %(committerdate:unix)' refs/heads/topic/ | sort -k2n | awk 'NR==2{print $1}')
near=$(git -C "$REPO" for-each-ref --format='%(refname:short) %(committerdate:unix)' refs/heads/topic/ | sort -k2nr | awk 'NR==2{print $1}')
say "deep branch: $deep ($(git -C "$REPO" rev-list --count "$deep..origin/main") base commits since merge-base), near branch: $near ($(git -C "$REPO" rev-list --count "$near..origin/main"))"
bench "git cherry origin/main $deep" "$RUNS" git -C "$REPO" cherry origin/main "$deep"
bench "git cherry origin/main $near" "$RUNS" git -C "$REPO" cherry origin/main "$near"
mb=$(git -C "$REPO" merge-base origin/main "$deep")
bench "pre-filter: rev-list --count origin/main..$deep" "$RUNS" git -C "$REPO" rev-list --count "origin/main..$deep"
# What `git cherry` does by hand: patch-ids of every base commit since the
# merge-base, vs only the base commits touching the paths the branch touches.
bench "patch-id of every base commit since merge-base (what cherry does)" "$RUNS" sh -c "cd '$REPO'; git rev-list origin/main ^$mb | git diff-tree --stdin -p | git patch-id --stable | wc -l"
bench "patch-id of base commits touching the branch's paths only" "$RUNS" sh -c "cd '$REPO'; git rev-list origin/main ^$mb -- \$(git diff --name-only $mb $deep) | git diff-tree --stdin -p | git patch-id --stable | wc -l"
bench "reflog show refs/heads/$deep (no -n)" "$RUNS" git -C "$REPO" reflog show --format=%gs "refs/heads/$deep"
bench "du -sk on the husk ($HUSK_FILES files)" "$RUNS" du -sk "$WT/old-husk"
bench 'lsof -t on a file' 1 lsof -t -- "$REPO/.git/HEAD"
bench 'lsof -n -P -t on a file' 1 lsof -n -P -t -- "$REPO/.git/HEAD"

fi

# ─── 5. brief ────────────────────────────────────────────────────────────────
if want 5; then

section "5. wts brief (no model: WTS_NO_LLM)"
note "Transcripts: 1 MB for every session, 10 MB for bench-1 and bench-2. The three \`grep\` of the whole file and the git calls run before the cache is consulted, so a cache hit costs the same as a miss minus the model call."
mk_transcript() { # <file> <MB>
  perl -e '
    my ($f, $mb) = @ARGV; open my $fh, ">", $f or die;
    my $line = q~{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"~ . ("working on it " x 20) . q~"}]}}~ . "\n";
    my $n = int($mb * 1024 * 1024 / length $line);
    print $fh q~{"type":"user","message":{"role":"user","content":"please rate limit the api"}}~ . "\n";
    print $fh $line for 1 .. $n;
    print $fh q~{"type":"ai-title","title":"Rate limiting"}~ . "\n";
    close $fh' "$1" "$2"
}
for (( n = 1; n <= SESSIONS; n++ )); do
  d="$CLAUDE_CONFIG_DIR/projects/${${WT}//[^a-zA-Z0-9]/-}-bench-$n"
  mkdir -p "$d"
  (( n <= 2 )) && mb=10 || mb=1
  mk_transcript "$d/sid-bench-$n.jsonl" "$mb"
done
say ""
table_head "brief"
bench 'wts brief (all sessions)' "$RUNS" "$WTS" brief
bench 'wts brief bench-1 (10 MB transcript)' "$RUNS" "$WTS" brief bench-1
bench 'wts brief bench-3 (1 MB transcript)' "$RUNS" "$WTS" brief bench-3
tr1="$CLAUDE_CONFIG_DIR/projects/${${WT}//[^a-zA-Z0-9]/-}-bench-1/sid-bench-1.jsonl"
bench '3x grep -F over 10 MB (transcript_last x3)' "$RUNS" sh -c "grep -F '\"type\":\"ai-title\"' '$tr1' | tail -1; grep -F '\"type\":\"pr-link\"' '$tr1' | tail -1; grep -F '\"type\":\"user\"' '$tr1' | tail -1"
bench '1x tail -c 2M | grep (bounded)' "$RUNS" sh -c "tail -c 2000000 '$tr1' | grep -F -e '\"type\":\"ai-title\"' -e '\"type\":\"pr-link\"' -e '\"type\":\"user\"' | tail -3"
bench 'git diff HEAD --shortstat (bench-3)' "$RUNS" env GIT_OPTIONAL_LOCKS=0 git -C "$WT/bench-3" diff HEAD --shortstat
say ""
count_head
count 'wts brief (all sessions)' "$WTS" brief

fi

# ─── 6. Switcher timeline ────────────────────────────────────────────────────
if want 6; then

# popup_timeline <refresh seconds>: opens wts-switch in a 120x30 window of the
# sandbox server (the switcher is the pane's process: no interactive shell, no
# rc files) and polls the screen every 100 ms. Reports the time to the first
# list (skeleton), the time until the AGENT column is filled (first complete
# collector pass) and what the poller spawned meanwhile. The shims go in front
# of PATH from inside the pane: tmux rebuilds PATH for a new pane, so
# `-e PATH=…` does not survive.
popup_timeline() {
  local refresh="$1" t0 t_skel="" t_full="" screen i ticks gits jqs
  cat > "$SANDBOX/switch-shimmed" <<EOF
#!/bin/sh
export PATH="$SANDBOX/shim:\$PATH" WTS_BENCH_PROCLOG="$WTS_BENCH_PROCLOG" WTS_SWITCH_REFRESH="$refresh"
exec "$HELPERS/wts-switch"
EOF
  chmod +x "$SANDBOX/switch-shimmed"
  : > "$WTS_BENCH_PROCLOG"
  t0=$EPOCHREALTIME
  tmux -S "$SOCK" new-session -d -s bench-ui -x 120 -y 30 "$SANDBOX/switch-shimmed"
  for i in {1..600}; do
    screen=$(tmux -S "$SOCK" capture-pane -p -t "=bench-ui:" 2>/dev/null)
    if [[ -z "$t_skel" ]] && print -r -- "$screen" | grep -q "bench-1 "; then t_skel=$(printf "%.2f" $(( EPOCHREALTIME - t0 ))); fi
    if print -r -- "$screen" | grep -qE 'blocked|working|idle'; then t_full=$(printf "%.2f" $(( EPOCHREALTIME - t0 ))); break; fi
    sleep 0.1
  done
  ticks=$(grep -c "^claude agents" "$WTS_BENCH_PROCLOG"); gits=$(grep -c '^git ' "$WTS_BENCH_PROCLOG"); jqs=$(grep -c '^jq ' "$WTS_BENCH_PROCLOG")
  say "WTS_SWITCH_REFRESH=$refresh:"
  say "- first list on screen (skeleton): ${t_skel:-n/a} s"
  if [[ -n "$t_full" ]]; then
    say "- agent column filled (first complete collector pass): $t_full s"
  else
    say "- agent column never filled in 60 s: $ticks collector passes started, none finished (each new tick replaces the one in flight). Screen after 60 s:"
    say '```'; print -r -- "$screen" | head -8 | tee -a "$RESULTS"; say '```'
  fi
  say "- meanwhile: $ticks collector passes started, $gits git and $jqs jq processes (a tick costs ~$TICK_MED s here)"
  say ""
  tmux -S "$SOCK" send-keys -t "=bench-ui:" Escape 2>/dev/null
  sleep 0.5
  tmux -S "$SOCK" kill-session -t "=bench-ui" 2>/dev/null
}

if [[ -z "$QUICK" ]]; then
section "6. The switcher, as seen by the user"
note "\`prefix+s\` with the default 2-second refresh, then with a refresh longer than a tick. The popup polls \`reload-sync\` every WTS_SWITCH_REFRESH seconds (\`wts-switch:726-736\`), and fzf drops the reload in flight when the next one arrives."
say ""
popup_timeline 2
popup_timeline 60
fi

fi

# ─── 7. Registry, restore, rm ────────────────────────────────────────────────
if want 7; then

section "7. Registry prune, stop/restore, rm"
say ""
table_head "command"
# Five registry entries whose worktree is gone: `registry_prune` rewrites the
# file once per entry, at the top of ls/status/brief/restore.
reg="$XDG_STATE_HOME/wts/sessions.json"
cp "$reg" "$SANDBOX/reg.bak"
for i in 1 2 3 4 5; do
  jq --arg n "gone-$i" --arg w "$WT/gone-$i" '.[$n] = {profile: "bench", repo_root: "'"$REPO"'", worktree: $w, branch: "feature/gone", subdir: "", context: "", prompt: "", created_at: "2026-01-01T00:00:00Z"}' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
done
bench 'wts ls with 5 stale registry entries (first run prunes)' 2 "$WTS" ls
"$WTS" stop bench-3 >/dev/null 2>&1 </dev/null
bench 'wts restore bench-3' 1 "$WTS" restore bench-3
bench 'wts rm bench-3 (plain worktree)' 1 "$WTS" rm bench-3 -f
bench 'wts rm bench-2 (untracked build/, not ignored)' 1 "$WTS" rm bench-2 -f
bench 'wts rm bench-1 (ignored node_modules)' 1 "$WTS" rm bench-1 -f
if [[ -d "$WT/bench-1" ]]; then
  say ""
  say "After \`wts rm bench-1\`: \`$WT/bench-1\` still exists ($(du -sh "$WT/bench-1" | cut -f1)) — \`git worktree remove\` leaves ignored files behind (a husk, \`wts gc\` category 1)."
fi
[[ -d "$WT/bench-2" ]] && say "After \`wts rm bench-2\`: the untracked build/ tree made \`worktree remove\` refuse; \`-f\` forced it: exists=$([[ -d "$WT/bench-2" ]] && print yes || print no)."

fi

# ─── 8. fresh ────────────────────────────────────────────────────────────────
if want 8; then

section "8. wts-fresh (prefix+: then wts …)"
note "The tmux entry point: fetch of origin/main (single refspec, local bare origin here), best-effort fast-forward of the local main (a \`git status\` and a \`merge --ff-only\` on the main working tree), then the creation above. The local main is $BEHIND commits behind."
say ""
table_head "fresh"
t0=$EPOCHREALTIME
WTS_NO_ATTACH=1 "$HELPERS/wts-fresh" bench-fresh bench </dev/null > "$SANDBOX/fresh.out" 2>&1
say "$(printf '| %s | %.3f | - | - | 1 |' 'wts-fresh bench-fresh bench' $(( EPOCHREALTIME - t0 )))"
say ""
say "Output seen by the user (the window is otherwise blank):"
say '```'
sed 's/^/    /' "$SANDBOX/fresh.out" | head -20 | tee -a "$RESULTS"
say '```'

fi

# ─── Done ────────────────────────────────────────────────────────────────────

say ""
say "Total bench time: $(elapsed $T_START) s."
[[ -n "$OUT" ]] && cp "$RESULTS" "$OUT" && print -u2 "results: $OUT"
exit 0
