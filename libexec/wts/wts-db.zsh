# wts-db.zsh — the state database, sourced by bin/wts and every helper.
#
# All wts state lives in one SQLite file, ${XDG_STATE_HOME:-~/.local/state}/wts/wts.db:
#   sessions     the registry (what `wts ls` lists and `wts restore` restarts)
#   briefs       wts-brief's cache (key line + done/next)
#   pane_hashes  wts-status's stale watchdog (pane hash, since when)
#   doc_cache    wts-doc's fetched documents
#   kv           small caches (wts-doc's connector list)
#   notes        what the Claude agents leave for each other (`wts db set`)
#   tasks        the durable unit of work above a session (a Things 3 task)
#   task_notes   free text the author keeps ON a task, not on one of its sessions
#   task_docs    the context documents a task opens its sessions on
#   task_links   which session serves which task, while the session lives
#   archive      finished work: what `wts log` reports and nothing ever deletes
#   agent_panes  the tmux pane each agent reported from its own hooks
#   touches      the files each agent edited, relative to its worktree
#   pr_state     each session's pull request, CI and review, as gh last saw it
#   merge_checks whether each session's branch landed in the base, per tip
#
# Why a database: the registry used to be one JSON file rewritten whole with
# `jq … > tmp && mv` by bin/wts, wts-gc and wts-doc. Two writers at once lost one
# update, and there was no safe way to let every agent write too. WAL mode lets
# the switcher and any number of agents read while one process writes, and
# `.timeout` makes a second writer wait instead of failing "database is locked".
#
# Sourced, not executed: the switcher is on a hot path and a zsh fork per read
# would show. The caller sets nothing; everything here is derived from XDG.

WTS_STATE_DIR="${WTS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wts}"
WTS_DB="${WTS_DB:-$WTS_STATE_DIR/wts.db}"
WTS_DB_SCHEMA=7
# Where the helpers are, for the few functions below that call one. Top level:
# when this file is sourced, $0 is this file.
WTS_DB_HOME="${0:A:h}"

# What `wts setup claude --install` lets an agent run without a prompt, and what
# `wts doctor` checks for: read-only verbs, plus the notes an agent writes. An
# agent's first reflexes are `wts ls`, `wts task ls`, `wts doc ls`, and each one
# used to wait on a permission prompt. Never rm, gc, stop, send or a creation:
# those act on someone's work, and the user says yes to each.
typeset -ga WTS_CLAUDE_ALLOW
WTS_CLAUDE_ALLOW=(
  "Bash(wts db:*)" "Bash(wts task note:*)" "Bash(wts task show:*)" "Bash(wts task ls:*)"
  "Bash(wts status:*)" "Bash(wts ls:*)" "Bash(wts doc ls:*)" "Bash(wts doc show:*)"
  "Bash(wts log:*)" "Bash(wts help:*)" "Bash(wts doctor:*)" "Bash(wts brief --cached:*)"
  "Bash(wts wait:*)" "Bash(wts tail:*)"
)

db_available() {
  (( ${+commands[sqlite3]} ))
}

# `-init /dev/null`: a user's ~/.sqliterc (`.mode box`, `.headers on`) would
# change every output this file parses.
_db() {
  sqlite3 -init /dev/null -batch -bail -cmd '.timeout 5000' "$@"
}

# db_q <sql> — read-write. db_ro <sql> — read-only, and silent without a
# database: a reader never creates one.
db_q() {
  _db "$WTS_DB" "$@"
}

db_ro() {
  _db_exists || return 0
  _db -readonly "$WTS_DB" "$@"
}

# Whether there is a database to read. The first command after an upgrade may
# well be a reader (`wts pr`, the switcher): it imports the old files then,
# rather than reporting an empty registry until some writer happens to run.
_db_exists() {
  [[ -s "$WTS_DB" ]] && return 0
  [[ -e "$WTS_STATE_DIR/sessions.json" ]] && db_init 2>/dev/null
  [[ -s "$WTS_DB" ]]
}

# db_rows <sql> — read-only, fields separated by \x1f and rows ended by \x1e:
# prompts are free text, so neither TAB nor newline can delimit. Split with
# parameter flags, never with `read -d`:
#   out=$(db_rows …)
#   for row in "${(@ps:\x1e:)out}"; do
#     [[ -n "$row" ]] || continue
#     f=("${(@ps:\x1f:)row}")   # empty fields are kept
#   done
# `read -d` puts the TERMINAL in non-canonical mode through the shell's own tty
# (zsh opens /dev/tty at startup even in a script), whatever it reads from. Run
# by fzf — a reload or a preview, in a process group of its own — that is a
# terminal change from the background: SIGTTOU, and the process stops for good.
# The switcher's list stopped refreshing the moment a task row existed.
db_rows() {
  _db_exists || return 0
  _db -readonly -ascii "$WTS_DB" "$@"
}

# A SQL string literal. SQLite has no backslash escapes, so doubling the single
# quote is the whole job. Not `.param set`: its value is itself parsed as SQL.
sql_str() {
  local q="'"
  print -r -- "$q${1//$q/$q$q}$q"
}

# A parenthesized list of literals, for `IN`: sql_list a b c -> ('a','b','c').
sql_list() {
  local v out=""
  for v in "$@"; do out+="${out:+,}$(sql_str "$v")"; done
  print -r -- "(${out:-NULL})"
}

# Create the schema and import the pre-1.0 files, once. Fast path: a database
# already at WTS_DB_SCHEMA costs one sqlite3 call.
db_init() {
  db_available || return 1
  [[ -n "${_WTS_DB_READY:-}" ]] && return 0
  # `>=` and not `==`: a git checkout and a Homebrew install share this database
  # (see CLAUDE.md), and an older binary testing for equality wrote its own,
  # lower version back — the two then migrated against each other forever, one
  # write transaction per process each way. Every change here is additive, so a
  # database from a newer wts is readable by an older one.
  # Still guarded by -s: db_q opens read-write and would create the file.
  # An `if` and not `[[ … ]] && v=…`: bin/wts runs under `set -e` and sources
  # this file, so a guard that is false on a database that does not exist yet
  # would exit before the schema was ever created — every first run, silently.
  local v=""
  if [[ -s "$WTS_DB" ]]; then
    v=$(db_q 'PRAGMA user_version' 2>/dev/null) || v=""
  fi
  if [[ "$v" =~ '^[0-9]+$' ]] && (( v >= WTS_DB_SCHEMA )); then
    _WTS_DB_READY=1
    return 0
  fi
  mkdir -p "$WTS_STATE_DIR" 2>/dev/null || return 1
  # Persistent: every later connection opens in WAL. Outside the transaction,
  # SQLite refuses to change the journal mode inside one.
  db_q 'PRAGMA journal_mode=WAL' >/dev/null 2>&1

  local old="$WTS_STATE_DIR/sessions.json" docdir="$WTS_STATE_DIR/docs"
  local sql f slug imports=""
  # The import rides in the schema transaction: two first runs at once, one
  # waits on BEGIN IMMEDIATE, and INSERT OR IGNORE makes its own import a no-op.
  if [[ -s "$old" ]]; then
    # A corrupt file must not block the upgrade: it imports nothing and stays
    # there, renamed like a good one, for the user to inspect.
    imports+="
INSERT OR IGNORE INTO sessions
  SELECT key,
         coalesce(json_extract(value, '\$.profile'), ''),
         coalesce(json_extract(value, '\$.repo_root'), ''),
         coalesce(json_extract(value, '\$.worktree'), ''),
         coalesce(json_extract(value, '\$.branch'), ''),
         coalesce(json_extract(value, '\$.subdir'), ''),
         coalesce(json_extract(value, '\$.context'), ''),
         coalesce(json_extract(value, '\$.prompt'), ''),
         coalesce(json_extract(value, '\$.docs'), '[]'),
         coalesce(json_extract(value, '\$.created_at'),
                  strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  FROM json_each(CASE WHEN json_valid(readfile($(sql_str "$old")))
                      THEN readfile($(sql_str "$old")) ELSE '{}' END)
  WHERE json_type(value) = 'object';"
  fi
  # Fetched documents cost an MCP round trip each: worth carrying over. The
  # brief and pane-hash caches are not: they rebuild on the next run.
  for f in "$docdir"/*.json(N); do
    slug="${f:t:r}"
    [[ "$slug" == tools ]] && continue
    imports+="
INSERT OR IGNORE INTO doc_cache
  SELECT $(sql_str "$slug"), readfile($(sql_str "$docdir/$slug.md")),
         json_extract(m, '\$.fetched_at'), json_extract(m, '\$.bytes'),
         coalesce(json_extract(m, '\$.title'), ''), json_extract(m, '\$.ok'),
         coalesce(json_extract(m, '\$.error'), ''), json_extract(m, '\$.truncated')
  FROM (SELECT readfile($(sql_str "$f")) AS m) WHERE json_valid(m);"
  done

  sql="BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS sessions (
  name       TEXT PRIMARY KEY,
  profile    TEXT NOT NULL DEFAULT '',
  repo_root  TEXT NOT NULL DEFAULT '',
  worktree   TEXT NOT NULL DEFAULT '',
  branch     TEXT NOT NULL DEFAULT '',
  subdir     TEXT NOT NULL DEFAULT '',
  context    TEXT NOT NULL DEFAULT '',
  prompt     TEXT NOT NULL DEFAULT '',
  docs       TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS briefs (
  session    TEXT PRIMARY KEY,
  key        TEXT NOT NULL,
  body       TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pane_hashes (
  agent_session TEXT PRIMARY KEY,
  hash          TEXT NOT NULL,
  since         INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS doc_cache (
  slug       TEXT PRIMARY KEY,
  body       TEXT,
  fetched_at INTEGER,
  bytes      INTEGER NOT NULL DEFAULT 0,
  title      TEXT NOT NULL DEFAULT '',
  ok         INTEGER NOT NULL DEFAULT 0,
  error      TEXT NOT NULL DEFAULT '',
  truncated  INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS kv (
  key   TEXT PRIMARY KEY,
  value TEXT
);
CREATE TABLE IF NOT EXISTS notes (
  session    TEXT NOT NULL,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (session, key)
);
CREATE INDEX IF NOT EXISTS notes_by_time ON notes(updated_at);
-- What the agent itself reported, through the Claude Code hooks wts-hook is
-- installed on: prompt (UserPromptSubmit), stop (Stop), notification
-- (Notification, kind = its notification_type, message = its text) and end
-- (SessionEnd, kind = its reason). Written by the hook only, read by
-- wts-status for since-when and waiting-for, and as the state itself when
-- claude agents cannot be asked. Kept a week; gc drops removed sessions.
CREATE TABLE IF NOT EXISTS agent_events (
  id             INTEGER PRIMARY KEY,
  session        TEXT NOT NULL,
  claude_session TEXT NOT NULL DEFAULT '',
  event          TEXT NOT NULL,
  kind           TEXT NOT NULL DEFAULT '',
  message        TEXT NOT NULL DEFAULT '',
  at             INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS agent_events_by_session ON agent_events(session, at);
-- A durable unit of work above the session: a task lives for months and gets
-- 1..N sessions, a session lives for days. NOT a mirror of the Things database,
-- which wts-log reads live: only the tasks wts was pointed at are here. A
-- snapshot is kept anyway, because the archive must still be able to name the
-- work when Things is uninstalled, the task edited, or the machine another one.
-- source: 'things' (id is TMTask.uuid, the Things Cloud id, stable across
-- devices) or 'local', because wts has to work on a machine without Things.
CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY,
  source       TEXT NOT NULL DEFAULT 'things',
  title        TEXT NOT NULL DEFAULT '',
  notes        TEXT NOT NULL DEFAULT '',
  links        TEXT NOT NULL DEFAULT '[]',
  status       TEXT NOT NULL DEFAULT 'open',
  area         TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL DEFAULT '',
  completed_at TEXT NOT NULL DEFAULT '',
  synced_at    TEXT NOT NULL
);
-- The context the author keeps ON the task: free text, and the documents its
-- sessions should open on. Both belong to the task, so they outlive every
-- session that serves it and the second attempt starts where the first left off.
--
-- Tables of their own, and not two more columns on tasks, for two independent
-- reasons. snapshot() in wts-task overwrites every column it reads from Things
-- (last writer wins, by design: nothing is ever written back), so a column here
-- would be wiped by the next refresh. And db_init only ever runs CREATE TABLE IF
-- NOT EXISTS: a new table migrates itself on any existing database, while a new
-- column would silently never appear.
--
-- Notes are append-only rows and not one blob: each keeps the date it was
-- written, so the agent reading them sees what came last. wts task edit is the
-- one verb that replaces them.
CREATE TABLE IF NOT EXISTS task_notes (
  task     TEXT NOT NULL,
  body     TEXT NOT NULL,
  added_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS task_notes_by_task ON task_notes(task);
-- A slug of the wts doc library, not a URL: the slug is what materialize and
-- wts doc sync take, so a document on a task is the same object as one on a
-- session rather than a second kind of reference to the same page.
CREATE TABLE IF NOT EXISTS task_docs (
  task     TEXT NOT NULL,
  slug     TEXT NOT NULL,
  added_at TEXT NOT NULL,
  PRIMARY KEY (task, slug)
);
-- The live link, dropped with its session like briefs and notes: a session name
-- is reused (wts rm auth-form, then wts auth-form again), so a link that
-- outlived its session would hand the new incarnation the old one's task. The
-- durable link is archive.task, whose row is identified by (session,
-- created_at) and cannot be confused that way.
-- Nothing below may carry a backtick, a double quote or a dollar sign: this
-- whole block is one double-quoted zsh string (it interpolates the import
-- statements). A backtick runs as a command substitution, and a double quote
-- closes the string so the next newline ends the assignment and the rest of the
-- schema is read as commands. Both were found the hard way. Single quotes are
-- fine, which is why the SQL defaults below use them.
CREATE TABLE IF NOT EXISTS task_links (
  session   TEXT PRIMARY KEY,
  task      TEXT NOT NULL,
  linked_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS task_links_by_task ON task_links(task);
-- Finished work, written at teardown and never deleted: this is the index that
-- wts rm and wts gc used to destroy at the very moment it was complete. It
-- holds a pointer to the Claude transcript and a generated retrospective rather
-- than the conversation — and the retro is what survives, because Claude Code
-- deletes transcripts after 30 days by default while a performance review looks
-- six months back.
--
-- A table of its own and not a status column on sessions: a dead row there
-- would reach registry_json() and so wts-status, wts ls, the switcher's
-- two-second tick, wts-doc's agent_pane_of and wts-gc's busy check, five
-- readers whose shared invariant is that the worktree exists — and
-- registry_prune() would delete it on the next listing anyway.
--
-- (session, created_at) is UNIQUE and not the primary key: INSERT OR IGNORE
-- then makes a second capture of the same session a no-op, and the rowid gives
-- wts-log a stable cursor.
CREATE TABLE IF NOT EXISTS archive (
  id               INTEGER PRIMARY KEY,
  session          TEXT NOT NULL,
  task             TEXT NOT NULL DEFAULT '',
  repo_root        TEXT NOT NULL DEFAULT '',
  branch           TEXT NOT NULL DEFAULT '',
  base             TEXT NOT NULL DEFAULT '',
  subdir           TEXT NOT NULL DEFAULT '',
  prompt           TEXT NOT NULL DEFAULT '',
  context          TEXT NOT NULL DEFAULT '',
  docs             TEXT NOT NULL DEFAULT '[]',
  brief            TEXT NOT NULL DEFAULT '',
  notes            TEXT NOT NULL DEFAULT '{}',
  outcome          TEXT NOT NULL DEFAULT 'unknown',
  pr_url           TEXT NOT NULL DEFAULT '',
  title            TEXT NOT NULL DEFAULT '',
  commits          TEXT NOT NULL DEFAULT '',
  files            TEXT NOT NULL DEFAULT '',
  added            INTEGER NOT NULL DEFAULT 0,
  removed          INTEGER NOT NULL DEFAULT 0,
  commit_count     INTEGER NOT NULL DEFAULT 0,
  file_count       INTEGER NOT NULL DEFAULT 0,
  transcript       TEXT NOT NULL DEFAULT '',
  claude_session   TEXT NOT NULL DEFAULT '',
  transcript_bytes INTEGER NOT NULL DEFAULT 0,
  transcript_mtime INTEGER NOT NULL DEFAULT 0,
  retro_delivered  TEXT NOT NULL DEFAULT '',
  retro_resisted   TEXT NOT NULL DEFAULT '',
  retro_resolved   TEXT NOT NULL DEFAULT '',
  retro_abandoned  TEXT NOT NULL DEFAULT '',
  retro_model      TEXT NOT NULL DEFAULT '',
  retro_error      TEXT NOT NULL DEFAULT '',
  retro_at         INTEGER NOT NULL DEFAULT 0,
  created_at       TEXT NOT NULL DEFAULT '',
  finished_at      TEXT NOT NULL,
  UNIQUE (session, created_at)
);
CREATE INDEX IF NOT EXISTS archive_by_finish ON archive(finished_at);
CREATE INDEX IF NOT EXISTS archive_by_task   ON archive(task);
-- The pane each agent runs in, as its own hooks saw it (TMUX_PANE in the
-- agent's environment): exact, where the collector has to match a Claude
-- session file to a pane and the pane's command is Claude Code's version
-- number. What wts send and the switcher's reply type into. Kept with its
-- session, dropped with it.
CREATE TABLE IF NOT EXISTS agent_panes (
  session        TEXT PRIMARY KEY,
  claude_session TEXT NOT NULL DEFAULT '',
  pane           TEXT NOT NULL,
  at             INTEGER NOT NULL
);
-- Every file an agent edited (PostToolUse on Edit, Write, MultiEdit,
-- NotebookEdit), relative to its worktree: two sessions of one repository
-- touching the same relative path is the overlap the hook warns about. One row
-- per session and path, the first time; at is that first time.
CREATE TABLE IF NOT EXISTS touches (
  session TEXT NOT NULL,
  path    TEXT NOT NULL,
  at      INTEGER NOT NULL,
  PRIMARY KEY (session, path)
);
CREATE INDEX IF NOT EXISTS touches_by_path ON touches(path);
-- The pull request of each session as gh last reported it: written by wts-pr
-- only, on wts pr --refresh or the switcher's slow timer, never on the
-- 2-second tick (one network round trip per session). state is open, closed,
-- merged, or none when gh found no PR for the branch; review and checks are
-- normalized (approved, changes_requested, review_required; pass, fail,
-- pending), empty when there is nothing to report. A failed call keeps the last
-- good values and only sets error and checked_at: an expired gh login must not
-- erase what the list showed. Dropped with its session.
CREATE TABLE IF NOT EXISTS pr_state (
  session    TEXT PRIMARY KEY,
  branch     TEXT NOT NULL DEFAULT '',
  number     INTEGER,
  state      TEXT NOT NULL DEFAULT '',
  review     TEXT NOT NULL DEFAULT '',
  checks     TEXT NOT NULL DEFAULT '',
  merged_at  TEXT NOT NULL DEFAULT '',
  url        TEXT NOT NULL DEFAULT '',
  error      TEXT NOT NULL DEFAULT '',
  fetched_at INTEGER NOT NULL DEFAULT 0,
  checked_at INTEGER NOT NULL DEFAULT 0
);
-- Whether a session's branch is in its base, squash and rebase included
-- (merge_verdict below), for one pair of tips. The patch-id test reads the
-- branch's diffs and the base's recent ones, too slow for every tick of the
-- switcher, and its answer only changes when one of the two tips moves: the
-- collector recomputes on a new pair and reads this row otherwise. Dropped with
-- its session.
CREATE TABLE IF NOT EXISTS merge_checks (
  session  TEXT PRIMARY KEY,
  tip      TEXT NOT NULL,
  base_tip TEXT NOT NULL,
  merged   TEXT NOT NULL DEFAULT '',
  at       INTEGER NOT NULL
);
$imports
PRAGMA user_version = $WTS_DB_SCHEMA;
COMMIT;"
  if ! print -r -- "$sql" | db_q >/dev/null; then
    print -u2 -r -- "⚠ wts: could not initialize $WTS_DB"
    return 1
  fi
  chmod 600 "$WTS_DB" 2>/dev/null

  if [[ -e "$old" ]]; then
    mv -f "$old" "$old.migrated" 2>/dev/null
    print -u2 -r -- "→ state imported into $WTS_DB ($(db_q 'SELECT count(*) FROM sessions') sessions; old file kept as sessions.json.migrated)"
  fi
  # Each `|| true`: bin/wts runs under `set -e` and sources this file, and on a
  # fresh install none of these paths exists — `rmdir` on a missing directory
  # returns 1 and used to abort the very first wts command of a new state
  # directory, after the schema was created but before anything was printed.
  rm -rf "$WTS_STATE_DIR/brief" "$WTS_STATE_DIR/panehash" 2>/dev/null || true
  rm -f "$docdir"/*.{md,json}(N) "$docdir"/.*(N) "$WTS_STATE_DIR"/sessions.json.tmp.*(N) 2>/dev/null || true
  rmdir "$docdir" 2>/dev/null || true
  _WTS_DB_READY=1
  return 0
}

# The registry as one JSON object, in the exact shape of the pre-1.0
# sessions.json ({name: {profile, repo_root, …, docs: [...]}}): the jq readers
# kept their filters, only their input changed. `task` and `task_title` were
# added on top, by correlated subquery over a table of at most a few dozen rows —
# additive, so a reader using // defaults is unaffected.
registry_json() {
  local out
  out=$(db_ro "SELECT json_group_object(name, json_object(
      'profile', profile, 'repo_root', repo_root, 'worktree', worktree,
      'branch', branch, 'subdir', subdir, 'context', context, 'prompt', prompt,
      'docs', json(docs), 'created_at', created_at,
      'task', coalesce((SELECT task FROM task_links l WHERE l.session = s.name), ''),
      'task_title', coalesce((SELECT t.title FROM task_links l
                              JOIN tasks t ON t.id = l.task
                              WHERE l.session = s.name), '')))
    FROM (SELECT * FROM sessions ORDER BY name) s" 2>/dev/null)
  [[ -n "$out" ]] || out='{}'
  print -r -- "$out"
}

db_has_session() {  # <name>
  [[ "$(db_ro "SELECT 1 FROM sessions WHERE name = $(sql_str "$1")" 2>/dev/null)" == 1 ]]
}

db_session_field() {  # <name> <column>
  db_ro "SELECT $2 FROM sessions WHERE name = $(sql_str "$1")" 2>/dev/null
}

# The task a live session serves, or nothing. The durable link is archive.task;
# this one dies with the session (see task_links above).
db_task_of_session() {  # <name>
  db_ro "SELECT task FROM task_links WHERE session = $(sql_str "$1")" 2>/dev/null
}

# A task's whole context as markdown: what the author put on the task rather
# than on one of its sessions. Sourced here and not a `wts task` verb because
# three helpers render it and one of them is wts-doc, which wts-task already
# execs — a verb would close the loop. Same reason wts-keys owns the key table.
#
# Database reads only: this runs inside the switcher's 2-second refresh and
# inside the Claude SessionStart hook, neither of which may call the model.
#
# <max attempts> is the "Previous attempts" block (task_attempts_md): 3 by
# default, 0 for none — the switcher places that block itself, next to the live
# sessions, rather than below a long note.
task_context_md() {  # <task id> [<max note lines>] [<max attempts>]
  local id="$1" cap="${2:-0}" attempts="${3:-3}"
  [[ -n "$id" ]] || return 1
  db_available || return 1

  local title notes st area out row
  local -a f
  # Split on \x1f and not read line by line: the notes are the author's free
  # text and hold newlines. Not `read -d` either: see db_rows.
  out=$(db_rows "
    SELECT title, notes, status, area FROM tasks WHERE id = $(sql_str "$id")" 2>/dev/null)
  f=("${(@ps:\x1f:)${out%$'\x1e'}}")
  title="${f[1]:-}" notes="${f[2]:-}" st="${f[3]:-}" area="${f[4]:-}"
  [[ -n "${title:-}" ]] || return 1

  print -r -- "## Task: $title"
  print -r -- "<!-- wts-task: $id -->"
  print -r -- "- status: ${st:-unknown}"
  [[ -n "${area:-}" ]] && print -r -- "- area: $area"
  print -r -- ""

  # Verbatim, newlines and all: this is the author's own text, and reflowing it
  # would break a pasted error message or a list of acceptance criteria.
  if [[ -n "${notes:-}" ]]; then
    print -r -- "Notes on the task (the author's own, verbatim):"
    print -r -- ""
    print -r -- "$notes"
    print -r -- ""
  fi

  local body at
  local -i n=0
  out=$(db_rows "SELECT substr(added_at, 1, 10), body FROM task_notes
                 WHERE task = $(sql_str "$id") ORDER BY added_at" 2>/dev/null)
  for row in "${(@ps:\x1e:)out}"; do
    f=("${(@ps:\x1f:)row}")
    at="${f[1]:-}" body="${f[2]:-}"
    [[ -n "$body" ]] || continue
    (( n++ == 0 )) && { print -r -- "Added in wts:"; print -r -- "" }
    print -r -- "- ($at) $body"
    (( cap > 0 && n >= cap )) && { print -r -- "- (…)"; break }
  done
  (( n )) && print -r -- ""

  (( attempts > 0 )) && task_attempts_md "$id" "$attempts"

  # Every link the task carries, even the ones that became documents below: an
  # agent that can reach a page itself should not have to guess its address.
  local url kind
  n=0
  # tasks.id and not id: json_each exposes an `id` column of its own, and an
  # unqualified one is ambiguous — sqlite refuses to prepare the statement.
  out=$(db_rows "SELECT json_extract(value, '\$.url'), json_extract(value, '\$.kind')
                 FROM tasks, json_each(tasks.links)
                 WHERE tasks.id = $(sql_str "$id") AND json_valid(tasks.links)" 2>/dev/null)
  for row in "${(@ps:\x1e:)out}"; do
    f=("${(@ps:\x1f:)row}")
    url="${f[1]:-}" kind="${f[2]:-}"
    [[ -n "$url" ]] || continue
    (( n++ == 0 )) && { print -r -- "Links in the task:"; print -r -- "" }
    print -r -- "- [${kind:-link}] $url"
  done
  (( n )) && print -r -- ""

  local slug
  n=0
  out=$(db_rows "SELECT slug FROM task_docs WHERE task = $(sql_str "$id")
                 ORDER BY added_at" 2>/dev/null)
  for slug in "${(@ps:\x1e:)out}"; do
    [[ -n "$slug" ]] || continue
    (( n++ == 0 )) && { print -r -- "Documents attached to the task:"; print -r -- "" }
    print -r -- "- $slug"
  done
  (( n )) && print -r -- ""
  return 0
}

# The sessions a task already had, from the archive, newest first: outcome, PR
# and the three retrospective lines a retry needs — what was hard, how it was
# overcome, what was dropped. The schema promised that "the second attempt
# starts where the first left off", and until this block nothing a new session
# reads carried the first attempt at all: wts task show printed `delivered`
# alone, and the context file and the hook not even that.
#
# Database reads only, like task_context_md: the switcher preview and the
# SessionStart hook call it. Each retro line is flattened and cut, since this
# block is re-injected into an agent's context at every start and /clear.
task_attempts_md() {  # <task id> [<max attempts>]
  local id="$1" max="${2:-3}"
  [[ -n "$id" ]] || return 1
  db_available || return 1
  local out row k v
  local -a f
  local -i n=0 total
  total=$(db_ro "SELECT count(*) FROM archive WHERE task = $(sql_str "$id")" 2>/dev/null)
  (( total > 0 )) || return 0
  out=$(db_rows "
    SELECT session, substr(finished_at, 1, 10), outcome, pr_url,
           retro_delivered, retro_resisted, retro_resolved, retro_abandoned, retro_error
      FROM archive WHERE task = $(sql_str "$id")
     ORDER BY finished_at DESC, id DESC LIMIT $(( max ))" 2>/dev/null)
  if (( total > max )); then
    print -r -- "Previous attempts (the last $max of $total, newest first):"
  else
    print -r -- "Previous attempts (newest first):"
  fi
  print -r -- ""
  for row in "${(@ps:\x1e:)out}"; do
    f=("${(@ps:\x1f:)row}")
    [[ -n "${f[1]:-}" ]] || continue
    (( n++ ))
    print -r -- "- ${f[1]} (${f[3]:-unknown}, ${f[2]:-?})${f[4]:+  ${f[4]}}"
    if [[ -z "${f[5]:-}${f[6]:-}${f[7]:-}${f[8]:-}" ]]; then
      print -r -- "  no retrospective yet${f[9]:+ (${f[9]//[[:cntrl:]]/ })}: wts retro"
      continue
    fi
    for k v in delivered "${f[5]:-}" resisted "${f[6]:-}" \
               resolved "${f[7]:-}" abandoned "${f[8]:-}"; do
      v="${v//[[:cntrl:]]/ }"
      # '-' and 'nothing notable' are the retro prompt's own words for "nothing
      # here", and wts-retro writes 'unknown' for a line the model left out.
      [[ -n "$v" && "$v" != (-|unknown|nothing notable) ]] || continue
      (( ${#v} > 160 )) && v="${v[1,159]}…"
      print -r -- "  $k: $v"
    done
  done
  (( total > max )) && print -r -- "- ($(( total - max )) earlier: wts task show $id)"
  print -r -- ""
  return 0
}

# git's common directory of a repository root, cached per process: the one
# definition of "same repository" (a session created from inside another
# worktree records that worktree as its root, so repo_root alone is not it).
typeset -gA _WTS_COMMON
db_common_of() {  # <repo_root>
  if [[ -z "${_WTS_COMMON[$1]+x}" ]]; then
    _WTS_COMMON[$1]=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [[ -n "${_WTS_COMMON[$1]}" ]] || _WTS_COMMON[$1]="$1"
  fi
  print -r -- "${_WTS_COMMON[$1]}"
}

# The other sessions of the same repository as <session>, newest first, one
# name per line. What the SessionStart hook lists, what the note line and the
# overlap warning are about: another repository's sessions cannot collide.
db_repo_siblings() {  # <session>
  local me="$1" mine name root out row
  local -a f
  mine=$(db_session_field "$me" repo_root)
  [[ -n "$mine" ]] || return 0
  mine=$(db_common_of "$mine")
  out=$(db_rows "SELECT name, repo_root FROM sessions
                 WHERE name != $(sql_str "$me") ORDER BY created_at DESC" 2>/dev/null)
  for row in "${(@ps:\x1e:)out}"; do
    f=("${(@ps:\x1f:)row}")
    name="${f[1]:-}" root="${f[2]:-}"
    [[ -n "$name" && -n "$root" ]] || continue
    [[ "$(db_common_of "$root")" == "$mine" ]] && print -r -- "$name"
  done
  return 0
}

# The tmux pane of <session>'s Claude agent, or failure — never a guess. The
# pane its hooks recorded, while it is still in that session; else the one the
# collector matched from Claude Code's session file. Typing into the session's
# active pane instead, as reply mode and `wts doc use` did, typed into the
# editor of the default layout.
agent_pane_of() {  # <session>
  local p s
  p=$(db_ro "SELECT pane FROM agent_panes WHERE session = $(sql_str "$1")" 2>/dev/null)
  if [[ -n "$p" ]]; then
    s=$(tmux display-message -p -t "$p" '#{session_name}' 2>/dev/null)
    if [[ "$s" == "$1" ]]; then
      print -r -- "$p"
      return 0
    fi
  fi
  if [[ -x "$WTS_DB_HOME/wts-status" ]] && command -v jq >/dev/null 2>&1; then
    p=$("$WTS_DB_HOME/wts-status" --json --no-git "$1" 2>/dev/null \
          | jq -r --arg n "$1" '.[] | select(.name == $n) | .agent_pane // empty' 2>/dev/null)
    if [[ "$p" == *%* ]]; then
      print -r -- "$p"
      return 0
    fi
  fi
  return 1
}

# The wts session the caller runs in, or failure. For `wts db` and the Claude
# SessionStart hook, both run from an agent's pane:
#  1. the pane's own session, through $TMUX_PANE. Not a bare `display-message
#     -p '#S'`: that names the most recently used session, not this one;
#  2. otherwise the registered worktree that contains the working directory,
#     the deepest one (a worktree may sit inside another's directory).
# Only a registered session counts: notes are keyed by it, and gc drops the
# rows of sessions that no longer exist.
db_current_session() {
  local s=""
  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]]; then
    s=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
    if [[ -n "$s" ]] && db_has_session "$s"; then
      print -r -- "$s"
      return 0
    fi
  fi
  local d
  for d in "$PWD" "${PWD:A}"; do
    s=$(db_ro "SELECT name FROM sessions
               WHERE worktree != '' AND (
                 $(sql_str "$d") = worktree
                 OR substr($(sql_str "$d/"), 1, length(worktree) + 1) = worktree || '/')
               ORDER BY length(worktree) DESC LIMIT 1" 2>/dev/null)
    if [[ -n "$s" ]]; then
      print -r -- "$s"
      return 0
    fi
  done
  return 1
}

# ─── Merged, squash included ─────────────────────────────────────────────────
# Shared by wts-gc (what to tear down), wts-status (the `merged` of the JSON and
# the switcher's `merged` label) and `wts rm` (whether the branch may go without
# -f). Until these moved here, only gc had them, and the collector's `merged`
# was `git branch --merged` alone: a squash-merged PR read `false` for good,
# while a session created a second ago read `true`.
#
# Why `git branch --merged` is not enough: it only recognizes merges by
# ancestry. PRs merged by squash or rebase rewrite SHAs, so the branch is never
# an ancestor of the base and `--merged` does not see it. So we also compare by
# patch-id, the test behind `git cherry`, hashed once for all branches: a
# branch whose every commit has an equivalent in the base is entirely present
# in it, whatever the merge mode.
#
# The caller picks a repository with merge_scope, then asks per branch. The
# results live in globals, not on stdout: called as `$(…)`, the per-repository
# hashes would be computed again for every branch (see CLAUDE.md).
typeset -gA MERGE_ANCESTRY MERGE_TRACK _MERGE_BASE_PID _MERGE_TIP_DATE _MERGE_OWN_PID
typeset -g MERGE_ROOT="" MERGE_BASE="" MERGE_BASE_REF=""
typeset -gi _MERGE_LOADED=0
typeset -ga _MERGE_ONLY

# The base of a repository, as wts-status and wts-gc detect it: WTS_BASE_BRANCH,
# else origin/HEAD, else main or master. -> MERGE_BASE (the short name) and
# MERGE_BASE_REF (origin/<base> when it exists: the local copy lags behind).
merge_base_of() {  # <repo_root>
  local root="$1" b="${WTS_BASE_BRANCH:-}" h c
  if [[ -z "$b" ]]; then
    # `|| h=""`: bin/wts sources this under `set -e`, and a repository without
    # origin/HEAD is normal.
    h=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || h=""
    if [[ -n "$h" ]]; then
      b="${h#origin/}"
    else
      for c in main master; do
        if git -C "$root" show-ref --verify --quiet "refs/heads/$c"; then
          b="$c"
          break
        fi
      done
    fi
  fi
  MERGE_BASE="$b" MERGE_BASE_REF="$b"
  if [[ -n "$b" ]] && git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$b"; then
    MERGE_BASE_REF="origin/$b"
  fi
  return 0
}

# Select a repository and read its branches' ancestry and tracking state: every
# local branch, or only the ones named (the collector asks about one at a time).
# `track` is "[gone]" when an upstream is configured but its tracking ref no
# longer exists (branch deleted on the remote, revealed by a fetch --prune).
# The `--format` of for-each-ref does not interpret \t (it would print the two
# literal characters); %1f does produce the 0x1f byte.
merge_scope() {  # <repo_root> <base> <base_ref> [branch...]
  MERGE_ROOT="$1" MERGE_BASE="$2" MERGE_BASE_REF="$3"
  shift 3
  _MERGE_ONLY=("$@")
  _MERGE_LOADED=0
  MERGE_ANCESTRY=() MERGE_TRACK=() _MERGE_BASE_PID=() _MERGE_TIP_DATE=() _MERGE_OWN_PID=()
  local b tr
  local -a refs
  if (( $# )); then refs=("${@/#/refs/heads/}"); else refs=(refs/heads/); fi
  while IFS=$'\x1f' read -r b tr; do
    [[ -n "$b" ]] && MERGE_TRACK[$b]="$tr"
  done < <(git -C "$MERGE_ROOT" for-each-ref \
    --format='%(refname:short)%1f%(upstream:track)' "${refs[@]}" 2>/dev/null)
  # Merged by ancestry (fast-forward or merge commit).
  if [[ -n "$MERGE_BASE" && -n "$MERGE_BASE_REF" ]]; then
    for b in "${(@f)$(git -C "$MERGE_ROOT" for-each-ref --merged "$MERGE_BASE_REF" \
                        --format='%(refname:short)' "${refs[@]}" 2>/dev/null)}"; do
      [[ -n "$b" ]] && MERGE_ANCESTRY[$b]=1
    done
  fi
  return 0
}

# Patch-ids, computed once for every branch in scope.
#
# This used to be `git cherry <base> <branch>` per branch, which computes a
# patch-id for every base commit since the merge-base again for each branch:
# 0.3 s per branch, 15 minutes for 3000 local branches on the repository
# measured in docs/big-repo-analysis.md. Two passes now hash everything once:
# the base's recent commits, and the own commits of every branch that is not an
# ancestor of the base (one `git log -p` fed by --stdin). Each branch then
# costs one `rev-list` and a few lookups.
#
# The base range: commits since the oldest tip among those branches, minus a
# day of slack. A squash or a rebase lands on the base after the commits it
# replaces were made (that is when the merge happened), so nothing older can be
# their equivalent. Each base entry keeps its commit date, so a branch's commits
# are only matched by base commits at least as new as the branch's tip: a change
# re-applied years after a base commit with the same diff stays unmerged, as
# `git cherry` bounded by the merge-base would have said.
merge_load() {
  (( _MERGE_LOADED )) && return 0
  _MERGE_LOADED=1
  [[ -n "$MERGE_BASE_REF" ]] || return 0
  local b d oldest="" pid cid
  local -a candidates refs
  local -A cdate
  if (( ${#_MERGE_ONLY} )); then refs=("${_MERGE_ONLY[@]/#/refs/heads/}"); else refs=(refs/heads/); fi
  while IFS=$'\x1f' read -r b d; do
    [[ -n "$b" ]] || continue
    _MERGE_TIP_DATE[$b]="$d"
    [[ "$b" != "$MERGE_BASE" && -z "${MERGE_ANCESTRY[$b]:-}" ]] || continue
    candidates+=("$b")
    if [[ -z "$oldest" ]] || (( d < oldest )); then oldest="$d"; fi
  done < <(git -C "$MERGE_ROOT" for-each-ref \
    --format='%(refname:short)%1f%(committerdate:unix)' "${refs[@]}" 2>/dev/null)
  (( ${#candidates} )) || return 0
  (( oldest -= 86400 ))
  while IFS=$'\x1f' read -r cid d; do
    [[ -n "$cid" ]] && cdate[$cid]="$d"
  done < <(git -C "$MERGE_ROOT" rev-list --since="@$oldest" --format='%H%x1f%ct' "$MERGE_BASE_REF" 2>/dev/null \
           | grep -v '^commit ')
  while read -r pid cid; do
    [[ -n "$pid" ]] && _MERGE_BASE_PID[$pid]="${cdate[$cid]:-0}"
  done < <(git -C "$MERGE_ROOT" rev-list --since="@$oldest" "$MERGE_BASE_REF" 2>/dev/null \
           | git -C "$MERGE_ROOT" diff-tree --stdin -p 2>/dev/null \
           | git -C "$MERGE_ROOT" patch-id --stable 2>/dev/null)
  while read -r pid cid; do
    [[ -n "$pid" ]] && _MERGE_OWN_PID[$cid]="$pid"
  done < <(print -rl -- "${candidates[@]}" "^$MERGE_BASE_REF" \
           | git -C "$MERGE_ROOT" log --stdin -p --no-merges --format='commit %H' 2>/dev/null \
           | git -C "$MERGE_ROOT" patch-id --stable 2>/dev/null)
  return 0
}

# True if every commit of <branch> has an equivalent (patch-id) in the base:
# content entirely present, squash and rebase included. A commit with an empty
# diff has no patch-id and nothing to be missing.
merge_content() {  # <branch>
  local b="$1" cid pid
  [[ -n "$MERGE_BASE_REF" ]] || return 1
  [[ -n "${MERGE_ANCESTRY[$b]:-}" ]] && return 0
  merge_load
  for cid in "${(@f)$(git -C "$MERGE_ROOT" rev-list --no-merges "$b" "^$MERGE_BASE_REF" 2>/dev/null)}"; do
    [[ -n "$cid" ]] || continue
    pid="${_MERGE_OWN_PID[$cid]:-}"
    [[ -n "$pid" ]] || continue
    (( ${+_MERGE_BASE_PID[$pid]} )) || return 1
    (( _MERGE_BASE_PID[$pid] + 86400 >= ${_MERGE_TIP_DATE[$b]:-0} )) || return 1
  done
  return 0
}

# True if <branch> was created and never received a commit. With zero commits
# of its own, a fresh branch is an ancestor of the base — exactly like a branch
# merged by fast-forward — and `git cherry` prints nothing for it: both would
# be classified as merged. `wts <name>` creates such a branch, and its agent
# may well be thinking without having written anything yet.
#
# The reflog tells them apart: `git worktree add -b` (and `git branch`) write a
# single "branch: Created from <base>" entry, and every commit, merge, rebase or
# reset adds another. A branch whose remote is `[gone]` was pushed, hence
# worked on: it is not new. An empty reflog (expired, or disabled with
# core.logAllRefUpdates) proves nothing, so the branch is judged as before.
merge_is_new() {  # <branch>
  local b="$1" ahead line
  local -a entries
  [[ "${MERGE_TRACK[$b]:-}" == "[gone]" ]] && return 1
  ahead=$(git -C "$MERGE_ROOT" rev-list --count "$MERGE_BASE_REF..$b" 2>/dev/null) || return 1
  (( ${ahead:-1} == 0 )) || return 1
  entries=("${(@f)$(git -C "$MERGE_ROOT" reflog show --format=%gs "refs/heads/$b" 2>/dev/null)}")
  entries=("${(@)entries:#}")
  (( ${#entries} )) || return 1
  for line in "${entries[@]}"; do
    [[ "$line" == "branch: Created from"* ]] || return 1
  done
  return 0
}

# The whole verdict, in the merge_scope'd repository: true when <branch> landed
# and is not merely new, with REPLY set to `merged` (ancestry) or `squashed`
# (patch-id) — the archive's own outcome words.
merge_verdict() {  # <branch>
  REPLY=""
  merge_content "$1" || return 1
  merge_is_new "$1" && return 1
  if [[ -n "${MERGE_ANCESTRY[$1]:-}" ]]; then REPLY=merged; else REPLY=squashed; fi
  return 0
}

# The verdict for one session at one pair of tips, computed and kept in
# merge_checks, where the collector reads it until a tip moves. -> REPLY
merge_check() {  # <session> <repo_root> <branch> <base> <base_ref> <tip> <base tip>
  local v
  merge_scope "$2" "$4" "$5" "$3"
  merge_verdict "$3" || REPLY=""
  v="$REPLY"
  db_q "INSERT OR REPLACE INTO merge_checks VALUES ($(sql_str "$1"), $(sql_str "$6"),
        $(sql_str "$7"), $(sql_str "$v"), ${EPOCHSECONDS:-$(date +%s)})" >/dev/null 2>&1
  REPLY="$v"
  return 0
}

# ─── Pull requests ───────────────────────────────────────────────────────────
# A pr_state row as the JSON object `wts status --json` and `wts pr --refresh
# --json` both carry under `pr` (the row aliased `p`). One definition, so the
# two contracts cannot drift apart.
WTS_PR_JSON="json_object('number', p.number, 'state', p.state,
  'review', nullif(p.review, ''), 'checks', nullif(p.checks, ''),
  'merged_at', nullif(p.merged_at, ''), 'url', nullif(p.url, ''),
  'refreshed_at', nullif(p.fetched_at, 0))"

# What the switcher's PR column says, per registered session: `#42 ✓`,
# `#42 ✗ci`, `#42 chg`, `#42 ...` (checks running), `closed`, `merged`, or
# nothing. Merged wins whoever says it, gh or the branch's own content: a squash
# merge reads merged before the next refresh, and a PR gh saw merged reads so
# before anyone fetched the base. The skeleton and the collected list both read
# this one query, so the column is the same width before and after the swap.
# ✓ and ✗ are East Asian Neutral, one column wide everywhere, so `emit` may pad
# them; the ellipsis is Ambiguous, hence the three dots.
db_pr_labels() {
  db_rows "SELECT s.name, CASE
      WHEN m.merged != '' OR p.state = 'merged' THEN 'merged'
      WHEN p.number IS NULL THEN ''
      WHEN p.state = 'closed' THEN 'closed'
      WHEN p.checks = 'fail' THEN '#' || p.number || ' ✗ci'
      WHEN p.review = 'changes_requested' THEN '#' || p.number || ' chg'
      WHEN p.checks = 'pending' THEN '#' || p.number || ' ...'
      ELSE '#' || p.number || ' ✓' END
    FROM sessions s
    LEFT JOIN pr_state p ON p.session = s.name
    LEFT JOIN merge_checks m ON m.session = s.name" 2>/dev/null
}

# ─── Claude transcripts ──────────────────────────────────────────────────────
# Same rule as `claude_project_dir` in wts: every non-alphanumeric -> "-".
db_claude_project_dir() {  # <dir>
  print -r -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${1//[^a-zA-Z0-9]/-}"
}

# The transcript of a session: the live agent's one when its id is known,
# otherwise the most recent one of the worktree or its subdirectory — exact
# paths, never a prefix (fix-login must not read fix-login-2), and never older
# than the session: an older file belongs to a previous incarnation of the same
# name (wts rm, then wts <name> again), whose work is unrelated.
# wts-brief, wts-retro and wts-pr read the same file this way.
db_session_transcript() {  # <worktree> <subdir> <created epoch> [<claude session id>]
  local worktree="$1" subdir="$2" created="${3:-0}" sid="${4:-}" d f tr=""
  integer m best=0
  local -a dirs
  dirs=("$(db_claude_project_dir "$worktree")")
  [[ -n "$subdir" ]] && dirs+=("$(db_claude_project_dir "$worktree/$subdir")")
  if [[ -n "$sid" ]]; then
    for d in "${dirs[@]}"; do
      if [[ -f "$d/$sid.jsonl" ]]; then
        print -r -- "$d/$sid.jsonl"
        return 0
      fi
    done
  fi
  zmodload -F zsh/stat b:zstat 2>/dev/null
  for d in "${dirs[@]}"; do
    for f in "$d"/*.jsonl(N); do
      m=$(zstat +mtime "$f" 2>/dev/null) || continue
      if (( m >= created && m > best )); then best=$m; tr="$f"; fi
    done
  done
  [[ -n "$tr" ]] || return 1
  print -r -- "$tr"
}

# The last pull request Claude Code linked in a transcript (its `pr-link`
# record), or nothing.
db_transcript_pr_url() {  # <transcript>
  [[ -f "$1" ]] || return 0
  grep -F '"type":"pr-link"' "$1" 2>/dev/null | tail -n 1 | jq -r '.prUrl // empty' 2>/dev/null
  return 0
}
