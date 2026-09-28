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
WTS_DB_SCHEMA=3

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
task_context_md() {  # <task id> [<max note lines>]
  local id="$1" cap="${2:-0}"
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
