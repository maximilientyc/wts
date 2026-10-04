#!/usr/bin/env zsh
# Records docs/db-browse.gif: `wts db browse`, the state database in fzf — the
# tables with their counts and schema, the rows of `archive` newest first with
# the record in the preview, esc back to the tables, enter printing a record.
# Like read-data.zsh, no agent and no model call: two sessions are created by
# wts, and the archive rows are written straight into the sandbox's database,
# which is exactly what `wts db` reads.
#
# Usage: VHS=/path/to/vhs-0.11 zsh docs/demo/db-browse.zsh
#
# vhs 0.12.0 exits 0 without writing the GIF (charmbracelet/vhs#787): 0.11.0.
# Everything lives under $D, on a tmux server of its own; your server, state
# and layouts are never touched.

set -uo pipefail

ROOT="${0:A:h:h:h}"
# Short and outside $TMPDIR: macOS caps the tmux socket path at 104 bytes.
D=/tmp/wts-dbbrowse

# Named by its socket only: with $TMUX set, a bare `tmux kill-server` goes to
# the server $TMUX names — yours (see new-task.zsh).
unset TMUX
SOCK="$D/tmux/tmux-$UID/default"
kill_sandbox() {
  [[ -S "$SOCK" ]] && tmux -S "$SOCK" kill-server 2>/dev/null
  return 0
}

if [[ "${1:-}" == "--setup" ]]; then
  unset WTS_LAYOUTS_PATH
  kill_sandbox
  rm -rf $D
  export TMUX_TMPDIR=$D/tmux XDG_STATE_HOME=$D/state XDG_CONFIG_HOME=$D/config \
    CLAUDE_CONFIG_DIR=$D/claude GIT_CONFIG_GLOBAL=$D/gitconfig GIT_CONFIG_NOSYSTEM=1 \
    WTS_NO_LLM=1 WTS_NO_THINGS=1
  export PS1='%F{blue}%1~%f %F{magenta}❯%f '
  mkdir -p $TMUX_TMPDIR $XDG_STATE_HOME $XDG_CONFIG_HOME/wts/layouts $CLAUDE_CONFIG_DIR $D/bin
  git config --global user.name demo
  git config --global user.email demo@example.com
  git config --global init.defaultBranch main
  print -r -- '#!/bin/sh
[ "$1" = agents ] && { echo "[]"; exit 0; }
exec sleep 3600' > $D/bin/claude
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
  print "# api" > $D/code/api/README.md
  git -C $D/code/api add . && git -C $D/code/api commit -qm init
  cd $D/code/api || exit 1
  tmux -f /dev/null new-session -d -s base -c $D/code/api -x 148 -y 44
  tmux set -g default-command "exec zsh -f"
  tmux set -g status-right ""
  tmux set -g status-style "bg=#313244,fg=#cdd6f4"

  WTS_NO_ATTACH=1 wts auth-form "validate the email server-side" >/dev/null 2>&1
  WTS_NO_ATTACH=1 wts export-users-csv >/dev/null 2>&1
  # Four finished sessions, as `wts gc --apply` archives them.
  db=$XDG_STATE_HOME/wts/wts.db
  sqlite3 -init /dev/null $db "
    INSERT INTO archive (session, repo_root, branch, base, prompt, outcome, pr_url,
                         title, added, removed, commit_count, file_count,
                         retro_delivered, retro_resisted, retro_resolved,
                         retro_abandoned, created_at, finished_at) VALUES
    ('cors', '$D/code/api', 'cors', 'main', 'allow the dashboard origin',
     'squashed', 'https://github.com/acme/api/pull/38', 'CORS for the dashboard',
     42, 3, 2, 3, 'an allow list read from the config', 'preflight cached by the CDN',
     'Vary: Origin on every answer', '', '2026-09-21T09:12:00Z', '2026-09-21T15:40:00Z'),
    ('rate-limit', '$D/code/api', 'rate-limit', 'main', 'rate-limit the public API',
     'squashed', 'https://github.com/acme/api/pull/42', 'Token bucket per API key',
     188, 21, 5, 7, 'token bucket per key on /v1, with tests',
     'redis TTLs drifted under the test clock', 'injected the clock into the limiter',
     'per-route quotas, left for a decision', '2026-09-24T08:30:00Z', '2026-09-25T17:05:00Z'),
    ('sso-spike', '$D/code/api', 'sso-spike', 'main', 'try SAML login with okta',
     'abandoned', '', '', 0, 0, 1, 2, 'a working login against the okta sandbox',
     'the metadata URL rotates its certificate', '', 'the whole spike: SSO waits for Q1',
     '2026-09-27T10:00:00Z', '2026-09-27T16:20:00Z'),
    ('metering', '$D/code/api', 'metering', 'main', 'count requests per key per day',
     'merged', 'https://github.com/acme/api/pull/45', 'Daily request metering',
     96, 8, 3, 4, 'a daily counter per key, exported as CSV', 'time zones of the day boundary',
     'everything in UTC, said so in the CSV header', '', '2026-10-01T09:00:00Z',
     '2026-10-02T11:45:00Z')"
  tmux new-session -d -s browse -c $D/code/api
  tmux kill-session -t base
  clear
  exec tmux attach -t browse
fi

VHS="${VHS:-vhs}"
for c in "$VHS" gifsicle tmux tmuxinator sqlite3 fzf; do
  command -v "$c" >/dev/null || { print -u2 -r -- "db-browse: $c not found"; exit 1 }
done
[[ "$("$VHS" --version)" != *0.12.0* ]] || {
  print -u2 -r -- "db-browse: vhs 0.12.0 writes no output (charmbracelet/vhs#787): set VHS to 0.11.0"
  exit 1
}
cd "$ROOT" || exit 1
"$VHS" docs/demo/db-browse.tape >/dev/null || exit 1
gifsicle -O3 --lossy=30 --colors 128 db-browse.raw.gif -o docs/db-browse.gif
rm -f db-browse.raw.gif
kill_sandbox
rm -rf $D
print -r -- "wrote docs/db-browse.gif"
