#!/usr/bin/env zsh
# Records docs/demo.gif, the README demo: real Claude Code agents on a throwaway
# clone of this repository, in a private tmux server that loads your
# ~/.tmux.conf. Never touches your tmux server, registry, layouts or remote.
#
# Usage: make demo   (or: zsh docs/demo/record.zsh)
#
# Needs vhs, gifsicle, the "Hack Nerd Font Mono" font, a logged-in `claude`, and
# wts installed on PATH: the tape and your tmux bindings run the installed wts,
# not this checkout (`brew reinstall --HEAD maximilientyc/tap/wts` to record
# main). Each take costs a few agent turns and Haiku calls on your account.
#
#   VHS=/path/to/vhs     vhs 0.12.0 exits 0 without writing the GIF
#                        (charmbracelet/vhs#787); 0.11.0 works
#   WTS_DEMO_MODEL=...   model of the agents (default: sonnet)
#   WTS_DEMO_KEEP=1      leave the sandbox and its tmux server up afterwards

set -euo pipefail

ROOT="${0:A:h:h:h}"
TAPE="${0:A:h}/demo.tape"
OUT="$ROOT/docs/demo.gif"
VHS="${VHS:-vhs}"

# A fixed path, not mktemp: Claude Code records folder trust per repository
# path, so a stable clone is trusted once rather than on every take. Short and
# outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/private/tmp/wts-demo

# The VHS grid (demo.tape: Width 1400, Height 800, FontSize 14, Padding 20),
# minus tmux's status line. Sessions started off-camera are created detached,
# at default-size: at 80x24 their panes would be stretched unevenly on attach.
COLS=148 ROWS=45

die() { print -r -- "record: $*" >&2; exit 1 }

for c in "$VHS" gifsicle tmux tmuxinator claude jq wts; do
  command -v "$c" >/dev/null || die "$c not found"
done
[[ "$("$VHS" --version)" != *0.12.0* ]] ||
  die "vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to a 0.11.0 binary"
installed=$(wts --version) checkout=$("$ROOT/bin/wts" --version)
[[ "$installed" == "$checkout" ]] ||
  print -r -- "record: recording the installed $installed, this checkout is $checkout" >&2

export TMUX_TMPDIR="$D/tmux"
export XDG_STATE_HOME="$D/state"
# Layouts through WTS_LAYOUTS_PATH rather than a private XDG_CONFIG_HOME: panes
# inherit the environment, and nvim would start without your config. The folder
# stays empty, so sessions use the built-in default layout.
export WTS_LAYOUTS_PATH="$D/layouts"
# A file rather than nvim's start screen, which belongs to your config, not
# to wts. bin/wts opens on its usage.
export EDITOR="nvim bin/wts"
# Your zsh config, with the history in the sandbox: macOS's /etc/zshrc sets
# HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history before your .zshrc runs, so exporting
# HISTFILE is overwritten. A ZDOTDIR whose files only source yours is not.
export ZDOTDIR="$D/zdotdir"
export ANTHROPIC_MODEL="${WTS_DEMO_MODEL:-sonnet}"
unset TMUX WTS_BRANCH_PREFIX WTS_BASE_BRANCH WTS_SUBDIR WTS_WORKTREES_BASE WTS_NO_LLM

# The sandbox's own socket, named explicitly: tmux (3.4 and later) silently
# drops a TMUX_TMPDIR that does not exist and falls back to /tmp, so a bare
# `tmux kill-server` on a first take, before the folder existed, killed the
# real server and the terminal this script was started from.
SOCK="$TMUX_TMPDIR/tmux-$UID/default"
cleanup() {
  # Pane programs write their state on SIGHUP (nvim's shada): give them a
  # moment, or they recreate what rm just removed.
  if [[ -S "$SOCK" ]]; then
    tmux -S "$SOCK" kill-server 2>/dev/null && sleep 2
  fi
  rm -rf "$D"
  rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/-private-tmp-wts-demo(|-*)(N)
}
cleanup   # a previous take, interrupted or kept
[[ -n "${WTS_DEMO_KEEP:-}" ]] || trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$TMUX_TMPDIR" "$XDG_STATE_HOME" "$WTS_LAYOUTS_PATH" "$ZDOTDIR"
for f in .zshenv .zprofile .zshrc .zlogin; do
  if [[ -f "$HOME/$f" ]]; then print -r -- "source ${(q)HOME}/$f" > "$ZDOTDIR/$f"; fi
done

# A local bare repository stands in for origin: the squash merge below and the
# fetch in `wts gc` stay on this machine.
base=$(git -C "$ROOT" rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || base=origin/main
base=${base#origin/}
git clone -q --bare --single-branch --branch "$base" "$ROOT" "$D/origin.git"
git clone -q "$D/origin.git" "$D/wts"
cd "$D/wts"

# Holds the server up while default-size is set before the first wts session.
tmux new-session -d -s demo-bootstrap -x "$COLS" -y "$ROWS"
tmux set -g default-size "${COLS}x${ROWS}"

print "record: starting the off-camera sessions"
start() { WTS_NO_ATTACH=1 wts "$@" >/dev/null 2>&1 || die "wts $1 failed to start" }
start gc-quiet "Add a --quiet flag to wts gc. Before writing any code, ask me whether --quiet should also silence the warnings."
start review-helpers "Review every script in libexec/wts/ for edge cases the README does not document. Read only: do not edit anything. Then list them by script."
start name-fallback "In one sentence: what does libexec/wts/wts-name do when WTS_NO_LLM=1?"
start ignore-orig
tmux kill-session -t "=demo-bootstrap"

# ignore-orig: one commit, pushed, squash-merged into the base, remote branch
# deleted. That is the case `wts gc` exists for: git branch --merged misses it.
g() { git -c commit.gpgsign=false "$@" }
wt="$D/wts-worktrees/ignore-orig"
print -r -- '*.orig' >> "$wt/.gitignore"
g -C "$wt" commit -qam "Ignore *.orig merge leftovers"
g -C "$wt" push -q -u origin ignore-orig
g merge -q --squash ignore-orig
g commit -qm "Ignore *.orig merge leftovers (#12)"
g push -q origin "$base"
g push -q origin --delete ignore-orig

# Claude asks whether to trust a folder it has never seen, and the default
# answer is "No, exit": pick the other one. The answer is stored for the clone's
# path, so from the second take on this finds nothing to do.
# Then wait for the three states the switcher has to show.
ready() {
  wts status --json | jq -e 'map({(.name): .agent_state}) | add
    | .["gc-quiet"] == "blocked" and .["review-helpers"] == "working"
      and .["name-fallback"] == "idle"' >/dev/null
}
print "record: waiting for the agents (blocked, working, idle)"
integer waited=0
until ready; do
  for p in $(tmux list-panes -a -F '#{pane_id}'); do
    if tmux capture-pane -p -t "$p" | grep -q 'Yes, I trust this folder'; then
      tmux send-keys -t "$p" Down Enter
    fi
  done
  (( (waited += 3) <= 240 )) || { wts ls >&2; die "agents never reached their states" }
  sleep 3
done

print "record: recording"
cd "$D"
"$VHS" "$TAPE" >/dev/null
gifsicle -O3 --lossy=30 --colors 128 "$D/raw.gif" -o "$OUT"
print -r -- "record: ${OUT#$ROOT/} $(( $(wc -c < "$OUT") / 1024 )) KB"
