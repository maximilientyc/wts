# wts-db.zsh — the state database, sourced by bin/wts and every helper.
#
# All wts state lives in one SQLite file, ${XDG_STATE_HOME:-~/.local/state}/wts/wts.db:
#   sessions     the registry (what `wts ls` lists and `wts restore` restarts)
#   briefs       wts-brief's cache (key line + done/next)
#   pane_hashes  wts-status's stale watchdog (pane hash, since when)
#   doc_cache    wts-doc's fetched documents
#   kv           small caches (wts-doc's connector list, Things, claude.messaging)
#   notes        what the Claude agents leave for each other (`wts db set`)
#   tasks        the durable unit of work above a session (a Things 3 task)
#   task_notes   free text the author keeps ON a task, not on one of its sessions
#   task_docs    the context documents a task opens its sessions on
#   task_links   which session serves which task, while the session lives
#   archive      finished work: what `wts log` reports and nothing ever deletes
#   agent_panes  the tmux pane each agent reported from its own hooks
#   touches      the files each agent edited, relative to its worktree
#   usage        tokens per session, transcript and model, summed from transcripts
#   pr_state     each session's pull request, CI and review, as gh last saw it
#   merge_checks whether each session's branch landed in the base, per tip
#   agent_gauges what each agent's Claude Code status line last reported
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
WTS_DB_SCHEMA=12
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

# db_rows_rw <sql> — db_rows on a read-write connection, for a transaction that
# reads and writes at once (wts-hook marks what it delivers in the same BEGIN
# IMMEDIATE, so two hooks of one agent cannot both deliver). Split the same way.
db_rows_rw() {
  _db_exists || return 0
  _db -ascii "$WTS_DB" "$@"
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

# A digest of stdin, for equality only (the stale guard's pane hashes, the brief
# cache key). `shasum` is Perl's and some Linux images ship without it: piped
# into a missing command the hash was empty, and the stale guard silently off.
# sha1sum is coreutils', cksum is POSIX. One machine always takes the same.
hash_stdin() {
  if (( ${+commands[shasum]} )); then shasum | cut -d' ' -f1
  elif (( ${+commands[sha1sum]} )); then sha1sum | cut -d' ' -f1
  else cksum | tr ' ' -
  fi
}

# branch_prefix_of <layout file> — declared by a `# wts: branch_prefix=feature/`
# line in the layout. It is a YAML comment, so tmuxinator never sees it, and the
# convention travels with the layout instead of living in wts, which a
# package manager overwrites on every upgrade. $WTS_BRANCH_PREFIX wins, even
# when set to an empty string.
branch_prefix_of() {
  if (( ${+WTS_BRANCH_PREFIX} )); then
    print -r -- "$WTS_BRANCH_PREFIX"
    return 0
  fi
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ '^#[[:space:]]*wts:[[:space:]]*branch_prefix=([^[:space:]]*)' ]]; then
      print -r -- "${match[1]}"
      return 0
    fi
  done < "$1"
  return 0
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

  # A column on an existing table, which CREATE TABLE IF NOT EXISTS never adds.
  # SQLite has no ADD COLUMN IF NOT EXISTS, and a duplicate column fails the
  # statement: so it runs on its own, before the schema's transaction, only when
  # the column is missing, and a loser of a race between two first runs fails
  # harmlessly. Checked again after: the version is not raised over a table
  # still without it, and the next command tries again.
  # pr_state.head is schema 8, agent_panes.transcript schema 10, usage.cost_usd
  # schema 11 (what claude -p reported for one of wts's own calls, by
  # usage_add_call; NULL on the rows summed from transcripts). An entry is
  # table:column[:type], the type TEXT NOT NULL DEFAULT '' when it has none.
  local tc tbl col typ
  local -a tcf
  for tc in pr_state:head agent_panes:transcript usage:cost_usd:REAL; do
    tcf=("${(@s.:.)tc}")
    tbl="${tcf[1]}" col="${tcf[2]}" typ="${tcf[3]:-TEXT NOT NULL DEFAULT ''}"
    [[ "$(db_q "SELECT count(*) FROM sqlite_master WHERE name = '$tbl'" 2>/dev/null)" == 1 ]] || continue
    [[ "$(db_q "SELECT count(*) FROM pragma_table_info('$tbl') WHERE name = '$col'" 2>/dev/null)" == 1 ]] && continue
    db_q "ALTER TABLE $tbl ADD COLUMN $col $typ" >/dev/null 2>&1
    if [[ "$(db_q "SELECT count(*) FROM pragma_table_info('$tbl') WHERE name = '$col'" 2>/dev/null)" != 1 ]]; then
      print -u2 -r -- "⚠ wts: could not add $tbl.$col to $WTS_DB"
      return 1
    fi
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
-- installed on: prompt (UserPromptSubmit; kind = message and message = the
-- sender when the prompt is a message from another Claude session, or notice
-- for Claude Code's own notice about one), stop (Stop), notification
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
-- session, dropped with it. transcript (schema 10) is the transcript_path of
-- the hook's payload: the file itself, where the project directory derived
-- from the worktree is a guess Claude Code may stop matching.
CREATE TABLE IF NOT EXISTS agent_panes (
  session        TEXT PRIMARY KEY,
  claude_session TEXT NOT NULL DEFAULT '',
  pane           TEXT NOT NULL,
  at             INTEGER NOT NULL,
  transcript     TEXT NOT NULL DEFAULT ''
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
-- erase what the list showed. head is the sha of the PR's head commit (schema
-- 8): a PR merged at the branch's current tip says the branch landed, even when
-- its squash matches none of the branch's own commits. Dropped with its session.
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
  checked_at INTEGER NOT NULL DEFAULT 0,
  head       TEXT NOT NULL DEFAULT ''
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
-- What each session's agents consumed, summed from message.usage in the Claude
-- transcripts of its worktree: one row per transcript (the main one, each one
-- after a /clear, each subagent's) and per model and speed. Written by
-- wts-brief and wts-retro, the two readers of a transcript, never by a hook or
-- the switcher. Keyed by (session, created_at) like the archive, so a reused
-- name starts from zero and an archived session keeps its numbers: this table
-- outlives the session and is dropped only when neither the session nor its
-- archive row is left. bytes and mtime are the transcript's when it was summed:
-- an unchanged file is not read again.
--
-- Tokens and not dollars: prices change and are the reader's business, so the
-- cost is computed at read time (usage_cost_sql below). The exception is wts's
-- own headless calls (usage_add_call), one row per verb under the transcript
-- 'wts:name', 'wts:brief' or 'wts:retro': claude -p reports their cost itself,
-- kept in cost_usd (schema 11), which prices a model the table below does not
-- know. NULL everywhere else. A table of its own
-- rather than columns on archive, because db_init only ever runs CREATE TABLE
-- IF NOT EXISTS: a new column would never appear on an existing database.
CREATE TABLE IF NOT EXISTS usage (
  session     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  transcript  TEXT NOT NULL,
  model       TEXT NOT NULL DEFAULT '',
  speed       TEXT NOT NULL DEFAULT '',
  input       INTEGER NOT NULL DEFAULT 0,
  output      INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0,
  cache_write_1h INTEGER NOT NULL DEFAULT 0,
  cache_read  INTEGER NOT NULL DEFAULT 0,
  messages    INTEGER NOT NULL DEFAULT 0,
  bytes       INTEGER NOT NULL DEFAULT 0,
  mtime       INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL DEFAULT 0,
  cost_usd    REAL,
  PRIMARY KEY (session, created_at, transcript, model, speed)
);
-- What each agent has been told of the others (schema 9), written by the
-- hooks: wts-hook delivers what is new at a turn or an edit, wts-context marks
-- what SessionStart showed. One row per reader, stream and ref:
--   notes    ref = author || char(31) || key, mark = the value delivered
--   overlap  ref = other session || char(31) || path, mark = '1'
--   archive  ref = '', mark = the last archive id told about
-- Delivery used to compare a note's updated_at with the reader's previous
-- prompt, to the second: a note rewritten in the second it was read was lost,
-- and a sweep of agent_events changed what counted as new. A mark is exact.
-- A table of its own, no column on notes or touches: an older wts sharing the
-- database writes rows without it. A mark older than its reader's session, or
-- than the author's, is ignored: a name comes back, and an older wts removing
-- a session leaves its marks behind. Dropped with the reader.
CREATE TABLE IF NOT EXISTS seen (
  session TEXT NOT NULL,
  stream  TEXT NOT NULL,
  ref     TEXT NOT NULL DEFAULT '',
  mark    TEXT NOT NULL DEFAULT '',
  at      INTEGER NOT NULL,
  PRIMARY KEY (session, stream, ref)
);
-- What the agent's own Claude Code status line last reported (schema 12),
-- written by wts-hook statusline when the user opted into it (wts setup claude
-- --statusline): the share of the context window in use, the account's rate
-- limits as that agent saw them, and Claude Code's own running cost of the
-- conversation. One row per session and conversation, overwritten at every
-- refresh: the newest row is the gauge, and the sum of cost_usd over the
-- conversations is cost_reported_usd. A reading, not a ledger: the usage
-- table and the price table stay what the cost is computed from. NULL when
-- the payload did not say (no context before the first answer, no rate
-- limits for an API key). NUMERIC, not REAL: a 41 stays 41 in the JSON,
-- not 41.0. Rows older than their session are a former session
-- of the same name and are ignored by the readers; dropped with the session.
-- Schema 11 is usage.cost_usd; no column is added here, a table is.
CREATE TABLE IF NOT EXISTS agent_gauges (
  session        TEXT NOT NULL,
  claude_session TEXT NOT NULL DEFAULT '',
  model          TEXT NOT NULL DEFAULT '',
  cost_usd       NUMERIC,
  context_pct    NUMERIC,
  rate_5h        NUMERIC,
  rate_7d        NUMERIC,
  at             INTEGER NOT NULL,
  PRIMARY KEY (session, claude_session)
);
$imports
-- merge_checks is a cache of verdicts: a schema change may come with a new
-- test (8: squashes of several commits), and an old verdict stays until a tip
-- moves. Recomputed on the next collector pass.
DELETE FROM merge_checks;
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
    # Not `$(db_common_of …)`: the memo would be written in the substitution's
    # subshell and lost, one git call per session instead of one per root.
    db_common_of "$root" >/dev/null
    [[ "${_WTS_COMMON[$root]}" == "$mine" ]] && print -r -- "$name"
  done
  return 0
}

# A Notification whose kind means the agent cannot go on without a human. One
# list, for the collector's state and the hook's banner: with one each,
# `idle_prompt` read idle in the switcher while its banner said "needs you",
# right after the "is done" of the same idle turn. The array is for SQL
# (sql_list): the status line counts the blocked sessions in one query.
typeset -ga WTS_NEEDS_HUMAN
WTS_NEEDS_HUMAN=(permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input)
needs_human() {  # <notification_type>
  (( ${WTS_NEEDS_HUMAN[(Ie)$1]} ))
}

# The model a retrospective is written with: wts-retro calls it, and gc's dry
# run names it in the cost it announces, which must be the one --apply pays.
# Not WTS_MODEL alone: naming and `wts brief` want Haiku's speed, a
# retrospective is written once and kept for months, and Haiku got its counts
# wrong where Opus did not. Empty counts as unset, so `WTS_RETRO_MODEL=` falls
# back even where ~/.zshenv exports a default.
retro_model() {
  print -r -- "${WTS_RETRO_MODEL:-${WTS_MODEL:-haiku}}"
}

# "3h ago", from a number of seconds: one wording wherever an agent reads an
# age. A note's was a raw ISO timestamp at SessionStart and nothing at all at a
# turn's start, a brief's `1440m ago`.
age_ago() {  # <seconds>
  local s="${1:-}"
  [[ "$s" == <-> ]] || { print -r -- "?"; return 0 }
  if (( s < 60 )); then print -r -- "just now"
  elif (( s < 3600 )); then print -r -- "$(( s / 60 ))m ago"
  elif (( s < 86400 )); then print -r -- "$(( s / 3600 ))h ago"
  else print -r -- "$(( s / 86400 ))d ago"
  fi
}

# The Claude Code conversation of <session>'s agent, as its hooks named it, or
# failure. The pane row first: it lasts as long as the session. The events are
# swept after seven days, and `wts restore` read only those — a session left
# alone for a week came back on whatever conversation was newest in the
# directory, a side chat included. `wts tail` had a lookup of its own.
db_claude_session_of() {  # <session>
  local sid
  sid=$(db_ro "SELECT claude_session FROM agent_panes WHERE session = $(sql_str "$1")" 2>/dev/null)
  if [[ -z "$sid" ]]; then
    sid=$(db_ro "SELECT claude_session FROM agent_events WHERE session = $(sql_str "$1")
                 AND claude_session != '' ORDER BY at DESC, id DESC LIMIT 1" 2>/dev/null)
  fi
  [[ "$sid" =~ '^[0-9a-f-]+$' ]] || return 1
  print -r -- "$sid"
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

# ─── Claude Code's messages between sessions ────────────────────────────────
# Claude Code 2.1.224 and later delivers messages between the sessions of one
# machine (SendMessage, ListAgents, notify_when_idle, over a Unix socket per
# session). An agent that has them reaches a sibling without `wts send`, which
# can only type into its pane. Measured on 2.1.293: a message to an idle agent
# starts a turn, one to a working agent is read at its next tool round, and
# UserPromptSubmit fires for both with the message as the prompt (see
# claude_peer_prompt below).
WTS_CLAUDE_MESSAGING_MIN=2.1.224

# claude_messaging [--no-store] [<dir>] — whether this machine's agents can
# message each other, as one word and a detail:
#   available                    0
#   old <version>                1   claude older than WTS_CLAUDE_MESSAGING_MIN
#   refuse <settings file>       1   crossSessionInbound: refuse, nothing arrives
#   hold <settings file>         1   crossSessionInbound: hold, each message
#                                    waits for the user's approval
#   none                         1   no claude on PATH
# The version costs a `claude --version` (a quarter of a second) and this runs
# from the SessionStart hook: the verdict is cached in kv['claude.messaging'],
# keyed by the resolved binary and the mtimes of the settings that decide it,
# so it is computed again after an upgrade or a settings change, and not
# otherwise. <dir>'s own .claude/settings{,.local}.json are read on every call,
# uncached: a repository may tighten the setting (Claude Code lets it hold or
# refuse, never accept over the user). --no-store: compute without writing the
# cache (wts doctor writes nothing).
claude_messaging() {
  local store=true dir="" bin real ver verdict key cached f m worst="accept" where=""
  [[ "${1:-}" == --no-store ]] && { store=false; shift }
  dir="${1:-}"
  bin=$(command -v claude 2>/dev/null) || { print -r -- none; return 1 }
  real="${bin:A}"
  zmodload -F zsh/stat b:zstat 2>/dev/null
  local cdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local -a settings
  settings=("$cdir/settings.json" "$cdir/settings.local.json"
            "/Library/Application Support/ClaudeCode/managed-settings.json"
            "/etc/claude-code/managed-settings.json")
  key="$real:$(zstat +mtime "$real" 2>/dev/null)"
  for f in "${settings[@]}"; do
    [[ -f "$f" ]] && key+=":$(zstat +mtime "$f" 2>/dev/null)"
  done
  if db_available && [[ -s "$WTS_DB" ]]; then
    cached=$(db_ro "SELECT value FROM kv WHERE key = 'claude.messaging'" 2>/dev/null)
  fi
  if [[ -n "${cached:-}" && "${cached%|*}" == "$key" ]]; then
    verdict="${cached##*|}"
  else
    # The native installer's binary is .../versions/<version>: no process.
    if [[ "$real" =~ '/versions/([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
      ver="${match[1]}"
    else
      ver=$(perl -e 'alarm shift; exec @ARGV' 5 "$bin" --version 2>/dev/null \
              | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    autoload -Uz is-at-least
    if [[ -z "$ver" ]] || ! is-at-least "$WTS_CLAUDE_MESSAGING_MIN" "$ver"; then
      verdict="old ${ver:-unknown}"
    else
      verdict=available
      for f in "${settings[@]}"; do
        m=$(_claude_inbound_of "$f")
        case "$m" in
          refuse) worst=refuse where="$f" ;;
          hold) [[ "$worst" == refuse ]] || { worst=hold where="$f" } ;;
        esac
      done
      [[ "$worst" != accept ]] && verdict="$worst $where"
    fi
    if $store && db_available && [[ -s "$WTS_DB" ]]; then
      db_q "INSERT OR REPLACE INTO kv VALUES ('claude.messaging', $(sql_str "$key|$verdict"))" \
        >/dev/null 2>&1
    fi
  fi
  # A repository's own setting, on top of the machine's.
  if [[ "$verdict" == available || "$verdict" == hold\ * ]] && [[ -n "$dir" ]]; then
    for f in "$dir/.claude/settings.json" "$dir/.claude/settings.local.json"; do
      m=$(_claude_inbound_of "$f")
      if [[ "$m" == refuse ]]; then verdict="refuse $f"; break; fi
      [[ "$m" == hold && "$verdict" == available ]] && verdict="hold $f"
    done
  fi
  print -r -- "$verdict"
  [[ "$verdict" == available ]]
}

# The crossSessionInbound value of one settings file, or nothing. grep first:
# most files do not mention it, and jq is a process.
_claude_inbound_of() {  # <settings file>
  [[ -f "$1" ]] && grep -qs crossSessionInbound "$1" 2>/dev/null || return 0
  jq -r '.crossSessionInbound // empty | strings' "$1" 2>/dev/null
}

# The name each live agent answers SendMessage on, from Claude Code's own
# session files (<claude dir>/sessions/<pid>.json): one line per agent,
# "<cwd>\x1f<name>", interactive ones first, newest first. Read rather than
# assumed: a layout that passes `--name <session>` (the built-in ones) makes
# it the wts name, any other gets a derived one (<folder>-<two hex digits>),
# and a send to a name that is only a prefix is refused. Files whose pid is
# gone are skipped: Claude Code leaves them behind after a crash.
claude_peer_names() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions" row
  local -a files f
  files=("$dir"/*.json(N))
  (( ${#files} )) || return 0
  command -v jq >/dev/null 2>&1 || return 0
  for row in "${(@f)$(cat "${files[@]}" 2>/dev/null | jq -rs '
      map(select(type == "object" and .peerProtocol != null and (.name // "") != ""
                 and (.pid | type) == "number"))
      | sort_by([(if .kind == "interactive" then 0 else 1 end), -(.startedAt // 0)])
      | .[] | [(.pid | tostring), .cwd, (.name | gsub("[\\t\\n\\r\u001f\u001e]"; " "))]
      | join("\u001f")' 2>/dev/null)}"; do
    f=("${(@ps:\x1f:)row}")
    (( ${#f} == 3 )) || continue
    kill -0 "${f[1]}" 2>/dev/null || continue
    print -r -- "${f[2]}"$'\x1f'"${f[3]}"
  done
  return 0
}

# A prompt that is not the author's: a message from another session, or a
# notice Claude Code itself sends about one (idle, delivery). Measured on
# 2.1.293, UserPromptSubmit's prompt is the raw `<cross-session-message from=…
# from-name="<sender>" from-mode=…>` block, or `[Cross-session idle notice] …`.
# In the transcript the same turn is a user record with origin.kind "peer" (or
# isMeta and turnOrigin "system" for a notice), whose content starts with
# "Another Claude session sent a message:"; one read during a turn is a
# queued_command attachment, not a user record. JQ_AUTHORED is the test the
# brief and the retrospective apply to user records, so a sibling's words are
# not reported as the author's.
JQ_AUTHORED='def authored:
  (.isMeta != true) and ((.origin.kind // "human") == "human")
  and ((.turnOrigin // "human") == "human")
  and ((.message.content | type) == "string")
  and (.message.content | (startswith("<") or startswith("[Cross-session ")
                           or startswith("Another Claude session sent a message")) | not);'
claude_peer_prompt() {  # <prompt> — prints the sender (or "notice"), fails for the author's own
  local p="$1"
  if [[ "$p" == '<cross-session-message'* ]]; then
    if [[ "${p%%$'\n'*}" =~ 'from-name="([^"]*)"' ]]; then print -r -- "${match[1]}"; else print -r -- "?"; fi
    return 0
  fi
  [[ "$p" == '[Cross-session '* ]] && { print -r -- notice; return 0 }
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
# Patch-ids alone miss the most common merge of all: a squash of SEVERAL
# commits lands as one combined diff, which matches none of them. #39 and #40
# (4 and 3 commits) read merged:false, gc left them out and `wts rm -f`
# archived them `abandoned`. Two more witnesses cover it: a three-way merge of
# the branch into the base that changes nothing (merge_tree_landed), and a pull
# request gh saw merged at the branch's current tip (MERGE_PR_HEAD).
#
# The caller picks a repository with merge_scope, then asks per branch. The
# results live in globals, not on stdout: called as `$(…)`, the per-repository
# hashes would be computed again for every branch (see CLAUDE.md).
typeset -gA MERGE_ANCESTRY MERGE_TRACK MERGE_TIP MERGE_PR_HEAD
typeset -gA _MERGE_BASE_PID _MERGE_TIP_DATE _MERGE_OWN_PID
typeset -g MERGE_ROOT="" MERGE_BASE="" MERGE_BASE_REF="" _MERGE_BASE_TREE=""
typeset -gi _MERGE_LOADED=0
# -1 unknown, 0 no, 1 yes: whether git has `merge-tree --write-tree` (2.38).
typeset -gi _MERGE_TREE_OK=-1
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
  _MERGE_LOADED=0 _MERGE_BASE_TREE=""
  MERGE_ANCESTRY=() MERGE_TRACK=() MERGE_TIP=() MERGE_PR_HEAD=()
  _MERGE_BASE_PID=() _MERGE_TIP_DATE=() _MERGE_OWN_PID=()
  local b tr tip row key
  local -a refs f
  if (( $# )); then refs=("${@/#/refs/heads/}"); else refs=(refs/heads/); fi
  while IFS=$'\x1f' read -r b tr tip; do
    [[ -n "$b" ]] || continue
    MERGE_TRACK[$b]="$tr" MERGE_TIP[$b]="$tip"
  done < <(git -C "$MERGE_ROOT" for-each-ref \
    --format='%(refname:short)%1f%(upstream:track)%1f%(objectname)' "${refs[@]}" 2>/dev/null)
  # The pull requests gh last saw merged, by branch and head: wts-pr's cache,
  # a database read and never gh (see CLAUDE.md). The head pins it to one tip:
  # a commit added after the merge, or a reused branch name, is not covered.
  for row in "${(@ps:\x1e:)$(db_rows "SELECT branch, head FROM pr_state
                                       WHERE state = 'merged' AND head != ''" 2>/dev/null)}"; do
    f=("${(@ps:\x1f:)row}")
    [[ -n "${f[1]:-}" && -n "${f[2]:-}" ]] || continue
    key="${f[1]}"$'\x1f'"${f[2]}"
    MERGE_PR_HEAD[$key]=1
  done
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
# content entirely present, rebase and one-commit squash included. A commit
# with an empty diff has no patch-id and nothing to be missing.
merge_patch_ids() {  # <branch>
  local b="$1" cid pid
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

# True if merging <branch> into the base would change nothing: the three-way
# merge of the two tips is the base's own tree, so everything the branch did
# since the merge-base is already there, however it got there — a squash of any
# number of commits included. One `merge-tree` per branch, whose work follows
# the trees that differ rather than history, and only when the patch-ids said
# no: 8 ms a branch on the small bench, mostly the fork. A branch whose net
# change is nothing (a commit and its revert) has not landed anywhere and stays
# out, as the patch-ids leave it: checked on a match only, the rare case. Needs
# `merge-tree --write-tree` (git 2.38); older gits keep the patch-ids alone.
merge_tree_landed() {  # <branch>
  local b="$1" t mb v
  local -a trees match mbegin mend
  if (( _MERGE_TREE_OK < 0 )); then
    v=$(git version 2>/dev/null)
    _MERGE_TREE_OK=0
    if [[ "$v" =~ '([0-9]+)\.([0-9]+)' ]] \
         && (( match[1] > 2 || (match[1] == 2 && match[2] >= 38) )); then
      _MERGE_TREE_OK=1
    fi
  fi
  (( _MERGE_TREE_OK )) || return 1
  if [[ -z "$_MERGE_BASE_TREE" ]]; then
    _MERGE_BASE_TREE=$(git -C "$MERGE_ROOT" rev-parse --verify --quiet "$MERGE_BASE_REF^{tree}" 2>/dev/null)
    [[ -n "$_MERGE_BASE_TREE" ]] || return 1
  fi
  # Exit 1 is a conflict: the base holds something else there, not this.
  t=$(git -C "$MERGE_ROOT" merge-tree --write-tree --no-messages \
        "$MERGE_BASE_REF" "$b" 2>/dev/null) || return 1
  [[ "${t%%$'\n'*}" == "$_MERGE_BASE_TREE" ]] || return 1
  mb=$(git -C "$MERGE_ROOT" merge-base "$MERGE_BASE_REF" "$b" 2>/dev/null) || return 1
  trees=("${(@f)$(git -C "$MERGE_ROOT" rev-parse "$mb^{tree}" "$b^{tree}" 2>/dev/null)}")
  (( ${#trees} == 2 )) && [[ "${trees[1]}" != "${trees[2]}" ]]
}

# True if <branch>'s content is in the base: by ancestry, by patch-id, or by a
# merge that would change nothing. In that order, cheapest first.
merge_content() {  # <branch>
  local b="$1"
  [[ -n "$MERGE_BASE_REF" ]] || return 1
  [[ -n "${MERGE_ANCESTRY[$b]:-}" ]] && return 0
  merge_patch_ids "$b" && return 0
  merge_tree_landed "$b"
}

# True if gh saw a pull request of <branch> merged with the branch's current
# tip as its head. A witness for a base not fetched yet (`wts rm` does not
# fetch), and for a merge whose content test fails anyway (the base changed
# the same lines again since). No witness without a recorded head: rows from
# before schema 8 say nothing.
merge_pr_landed() {  # <branch>
  local key="$1"$'\x1f'"${MERGE_TIP[$1]:-}"
  [[ -n "${MERGE_TIP[$1]:-}" ]] || return 1
  (( ${+MERGE_PR_HEAD[$key]} ))
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
# (content or pull request) — the archive's own outcome words.
merge_verdict() {  # <branch>
  REPLY=""
  merge_content "$1" || merge_pr_landed "$1" || return 1
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
# With <session>, the transcript its hooks recorded comes first (agent_panes,
# from the payload's transcript_path), when the file is still there and not
# older than the session: Claude Code names it, wts no longer derives it. The
# project-directory slug stays as the fallback, for an agent whose hooks
# predate schema 10 and for a session whose row went with a teardown.
db_session_transcript() {  # <worktree> <subdir> <created epoch> [<claude session id>] [<session>]
  local worktree="$1" subdir="$2" created="${3:-0}" sid="${4:-}" session="${5:-}" d f tr=""
  integer m best=0
  local -a dirs
  zmodload -F zsh/stat b:zstat 2>/dev/null
  if [[ -n "$session" ]]; then
    tr=$(db_ro "SELECT transcript FROM agent_panes WHERE session = $(sql_str "$session")" 2>/dev/null)
    if [[ -n "$tr" && -f "$tr" ]] && (( $(zstat +mtime "$tr" 2>/dev/null || print 0) >= created )); then
      print -r -- "$tr"
      return 0
    fi
    tr=""
  fi
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

# ─── Usage: tokens per session ───────────────────────────────────────────────

# The transcripts a session's agents wrote, one path per line: every *.jsonl of
# the worktree's project directory (and its subdirectory's) no older than the
# session — a new file per /clear, and an older one belongs to a previous
# incarnation of the same name — plus the subagents' own files, which Claude
# Code keeps under <session id>/subagents/ and which cost as much as the rest.
# Same matching rule as wts-brief and wts-retro: exact directories, never a
# prefix (fix-login must not count fix-login-2).
usage_transcripts() {  # <worktree> <subdir> <created epoch>
  local wt="$1" sub="$2" created="${3:-0}" root d f p
  local -a dirs
  zmodload -F zsh/stat b:zstat 2>/dev/null
  root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  dirs=("$root/${wt//[^a-zA-Z0-9]/-}")
  p="$wt/$sub"
  [[ -n "$sub" ]] && dirs+=("$root/${p//[^a-zA-Z0-9]/-}")
  for d in "${dirs[@]}"; do
    for f in "$d"/*.jsonl(N) "$d"/*/subagents/*.jsonl(N); do
      (( $(zstat +mtime "$f" 2>/dev/null || print 0) >= created )) && print -r -- "$f"
    done
  done
  return 0
}

# Sum one transcript into the usage table, unless it has not changed since the
# last time. <file> may be gzipped (the archive keeps a .gz copy); <key> is the
# path the row is recorded under, the original one by default.
#
# Claude Code writes one record per content block of an assistant message, and
# each repeats the message's usage: summed naively, a turn with thinking, text
# and two tool calls counts four times. So one usage per message id, the
# largest (a streamed message's output count only grows). Model <synthetic>
# is Claude Code's own placeholder for a message no model wrote, at zero.
usage_store() {  # <session> <created_at> <file> [<key>]
  local session="$1" created="$2" file="$3" key="${4:-$3}"
  [[ -n "$session" && -f "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  zmodload -F zsh/stat b:zstat 2>/dev/null
  local bytes mtime seen where
  bytes=$(zstat +size "$file" 2>/dev/null) || return 0
  mtime=$(zstat +mtime "$file" 2>/dev/null) || return 0
  where="session = $(sql_str "$session") AND created_at = $(sql_str "$created")
         AND transcript = $(sql_str "$key")"
  seen=$(db_ro "SELECT bytes || ':' || mtime FROM usage WHERE $where LIMIT 1" 2>/dev/null)
  [[ "$seen" == "$bytes:$mtime" ]] && return 0

  local rows
  # grep first: a transcript is mostly tool results, and jq parsing them all
  # to keep one record in five is what made a 10 MB file cost half a second.
  rows=$( { if [[ "$file" == *.gz ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi } 2>/dev/null \
    | grep -F '"usage"' \
    | jq -Rrn '
        [inputs | fromjson?
         | select(.type == "assistant" and (.message.usage | type) == "object")
         | {k: (.message.id // .requestId // .uuid // ""),
            m: (.message.model // ""), s: (.message.usage.speed // ""),
            u: .message.usage}
         | select(.m != "<synthetic>")]
        | group_by(.k) | map(max_by(.u.output_tokens // 0))
        | group_by([.m, .s])[]
        | [ .[0].m, .[0].s,
            (map(.u.input_tokens // 0) | add),
            (map(.u.output_tokens // 0) | add),
            (map(.u.cache_creation_input_tokens // 0) | add),
            (map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add),
            (map(.u.cache_read_input_tokens // 0) | add),
            length ]
        | map(tostring) | join("\u001f")' 2>/dev/null)
  # No status test: under pipefail, grep finding no usage at all fails the
  # pipeline, and that file is exactly the one to remember as empty.

  # Columns named in the INSERT: the table grew one (cost_usd, schema 11), and a
  # positional list would fail on every database created before or after it.
  local sql row n
  local -a f
  sql="BEGIN IMMEDIATE; DELETE FROM usage WHERE $where;"
  n=0
  for row in "${(@f)rows}"; do
    [[ -n "$row" ]] || continue
    f=("${(@ps:\x1f:)row}")
    (( ${#f} == 8 )) || continue
    (( n++ ))
    sql+="
INSERT OR REPLACE INTO usage (session, created_at, transcript, model, speed, input,
  output, cache_write, cache_write_1h, cache_read, messages, bytes, mtime, updated_at)
  VALUES ($(sql_str "$session"), $(sql_str "$created"),
  $(sql_str "$key"), $(sql_str "${f[1]}"), $(sql_str "${f[2]}"),
  ${${f[3]//[^0-9]/}:-0}, ${${f[4]//[^0-9]/}:-0}, ${${f[5]//[^0-9]/}:-0},
  ${${f[6]//[^0-9]/}:-0}, ${${f[7]//[^0-9]/}:-0}, ${${f[8]//[^0-9]/}:-0},
  ${bytes//[^0-9]/}, ${mtime//[^0-9]/}, unixepoch());"
  done
  # A transcript with no usage yet (a session opened, nothing asked) still
  # gets a row, so its signature is remembered and it is not read again.
  (( n )) || sql+="
INSERT OR REPLACE INTO usage (session, created_at, transcript, bytes, mtime, updated_at)
  VALUES ($(sql_str "$session"), $(sql_str "$created"), $(sql_str "$key"),
          ${bytes//[^0-9]/}, ${mtime//[^0-9]/}, unixepoch());"
  sql+="
COMMIT;"
  print -r -- "$sql" | db_q >/dev/null 2>&1
  return 0
}

# Add one of wts's own headless calls to the usage table: <verb> is name, brief
# or retro, and stdin is what `claude -p --output-format json` printed. The
# tokens come from its usage, the model from modelUsage (the one that cost the
# most), the cost from total_cost_usd, which is Claude Code's own list price:
# usage_cost_sql has no price for a model released after it was written, and
# Haiku is the one these calls use. One row per session incarnation, verb and
# model, under the transcript 'wts:<verb>', that each call adds to; messages
# counts the calls. usage_store deletes only rows keyed by a file path, so
# usage_refresh leaves these alone, and they go with the incarnation like the
# rest (usage_prune_sql). An empty <created_at> is the registered session's: a
# brief, or a name recorded right after registry_put.
usage_add_call() {  # <session> <created_at|''> <verb> ; JSON on stdin
  local session="$1" created="$2" verb="$3" row
  [[ -n "$session" && -n "$verb" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  row=$(jq -r 'select(type == "object" and (.usage | type) == "object")
      | [ ((.modelUsage // {}) | to_entries | max_by(.value.costUSD // 0) | .key? // ""),
          (.usage.speed // ""),
          (.usage.input_tokens // 0), (.usage.output_tokens // 0),
          (.usage.cache_creation_input_tokens // 0),
          (.usage.cache_creation.ephemeral_1h_input_tokens // 0),
          (.usage.cache_read_input_tokens // 0),
          (.total_cost_usd // "") ]
      | map(tostring) | join("\u001f")' 2>/dev/null) || return 0
  [[ -n "$row" ]] || return 0
  local -a f
  f=("${(@ps:\x1f:)row}")
  (( ${#f} == 8 )) || return 0
  local c cost="${f[8]}"
  if [[ -n "$created" ]]; then
    c=$(sql_str "$created")
  else
    c="(SELECT created_at FROM sessions WHERE name = $(sql_str "$session"))"
  fi
  # A number or NULL, never text: it goes into the SQL unquoted.
  [[ "$cost" =~ '^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' ]] || cost="NULL"
  db_init 2>/dev/null || return 0
  db_q "INSERT INTO usage (session, created_at, transcript, model, speed, input, output,
          cache_write, cache_write_1h, cache_read, messages, cost_usd, updated_at)
        VALUES ($(sql_str "$session"), $c, $(sql_str "wts:$verb"),
          $(sql_str "${f[1]}"), $(sql_str "${f[2]}"),
          ${${f[3]//[^0-9]/}:-0}, ${${f[4]//[^0-9]/}:-0}, ${${f[5]//[^0-9]/}:-0},
          ${${f[6]//[^0-9]/}:-0}, ${${f[7]//[^0-9]/}:-0}, 1, $cost, unixepoch())
        ON CONFLICT (session, created_at, transcript, model, speed) DO UPDATE SET
          input = usage.input + excluded.input, output = usage.output + excluded.output,
          cache_write = usage.cache_write + excluded.cache_write,
          cache_write_1h = usage.cache_write_1h + excluded.cache_write_1h,
          cache_read = usage.cache_read + excluded.cache_read,
          messages = usage.messages + 1,
          cost_usd = usage.cost_usd + excluded.cost_usd,
          updated_at = excluded.updated_at" >/dev/null 2>&1
  return 0
}

# Refresh the usage of registered sessions (all of them without a name) from
# their transcripts. Reads the transcripts: only wts-brief and wts-retro call
# it, never ls, the switcher or a hook, which only read the table.
usage_refresh() {  # [<session>...]
  command -v jq >/dev/null 2>&1 || return 0
  db_init 2>/dev/null || return 0
  local filter="" out row tr
  local -a f
  (( $# )) && filter="WHERE name IN $(sql_list "$@")"
  out=$(db_rows "SELECT name, worktree, subdir, created_at,
                        coalesce(strftime('%s', created_at), 0)
                 FROM sessions $filter" 2>/dev/null)
  for row in "${(@ps:\x1e:)out}"; do
    f=("${(@ps:\x1f:)row}")
    [[ -n "${f[1]:-}" && -n "${f[2]:-}" ]] || continue
    for tr in "${(@f)$(usage_transcripts "${f[2]}" "${f[3]:-}" "${f[5]:-0}")}"; do
      [[ -n "$tr" ]] && usage_store "${f[1]}" "${f[4]:-}" "$tr"
    done
  done
  return 0
}

# The list price in USD of a usage row aliased <a>, as a SQL expression, NULL
# for a model this table does not know. List prices of the Claude API per
# million tokens: input, output, cache read. A cache write costs 1.25x input
# (5-minute TTL) or 2x (1-hour TTL, what Claude Code uses); fast mode doubles
# all of it. This is what the tokens would cost on the API, not what a
# subscription bills, and it is computed at read time so that a price change
# is one edit here rather than a migration. First match wins: specific first.
usage_cost_sql() {  # <alias>
  local a="$1"
  # cost_usd first: the price claude -p reported for wts's own calls
  # (usage_add_call). NULL on every row summed from a transcript.
  print -r -- "coalesce($a.cost_usd, (SELECT ($a.input * p.column3 + $a.output * p.column4
      + ($a.cache_write - $a.cache_write_1h) * p.column3 * 1.25
      + $a.cache_write_1h * p.column3 * 2 + $a.cache_read * p.column5)
      * (CASE $a.speed WHEN 'fast' THEN 2 ELSE 1 END) / 1000000.0
    FROM (VALUES
      (1,  'claude-fable-5-1*',   10,  50,  0.25),
      (2,  'claude-mythos-5-1*',  10,  50,  0.25),
      (3,  'claude-fable-5*',     10,  50,  1.0),
      (4,  'claude-mythos-5*',    10,  50,  1.0),
      (5,  'claude-opus-5-5*',     4,  20,  0.2),
      (6,  'claude-opus-5*',       5,  25,  0.5),
      (7,  'claude-opus-4-[5-9]*', 5,  25,  0.5),
      (8,  'claude-opus-4*',      15,  75,  1.5),
      (9,  'claude-sonnet-5*',     2,  10,  0.2),
      (10, 'claude-sonnet-4*',     3,  15,  0.3),
      (11, 'claude-3-7-sonnet*',   3,  15,  0.3),
      (12, 'claude-haiku-4-5*',    1,   5,  0.1),
      (13, 'claude-3-5-haiku*',  0.8,   4,  0.08)) p
    WHERE $a.model GLOB p.column2 ORDER BY p.column1 LIMIT 1))"
}

# The usage of one session incarnation as a SQL expression yielding a JSON
# object, or NULL when nothing was ever summed for it. <session> and <created>
# are SQL expressions (a column of the outer query, or a literal). The shape is
# what wts status --json and wts log carry under "usage":
#   {input, output, cache_write, cache_read, tokens, messages, cost_usd,
#    cost_complete, model, models: [{model, speed, ..., cost_usd}], updated_at}
# tokens is the four counts added; model is the one that cost the most;
# cost_complete is false when some model has no price here, in which case
# cost_usd counts only the priced ones.
usage_json_sql() {  # <session expr> <created expr>
  local s="$1" c="$2" cost
  cost=$(usage_cost_sql u)
  print -r -- "(SELECT CASE WHEN count(*) = 0 THEN NULL ELSE json_object(
      'input', sum(input), 'output', sum(output),
      'cache_write', sum(cache_write), 'cache_read', sum(cache_read),
      'tokens', sum(input + output + cache_write + cache_read),
      'messages', sum(messages),
      'cost_usd', round(coalesce(sum(cost), 0), 4),
      'cost_complete', json(CASE WHEN sum(model != '' AND cost IS NULL) > 0
                                 THEN 'false' ELSE 'true' END),
      'model', (SELECT model FROM usage x WHERE x.session = $s AND x.created_at = $c
                AND x.model != '' GROUP BY model
                ORDER BY sum(x.output + x.input + x.cache_write) DESC LIMIT 1),
      'models', (SELECT json_group_array(json_object('model', model, 'speed', speed,
                   'input', i, 'output', o, 'cache_write', w, 'cache_read', r,
                   'messages', n, 'cost_usd', CASE WHEN c IS NULL THEN NULL ELSE round(c, 4) END))
                 FROM (SELECT model, speed, sum(input) i, sum(output) o,
                              sum(cache_write) w, sum(cache_read) r, sum(messages) n,
                              sum($cost) c
                       FROM usage u WHERE u.session = $s AND u.created_at = $c
                         AND u.model != '' GROUP BY model, speed
                       ORDER BY c DESC)),
      'updated_at', max(updated_at)) END
    FROM (SELECT u.*, $cost AS cost FROM usage u
          WHERE u.session = $s AND u.created_at = $c))"
}

# The usage rows of incarnations that are neither registered nor archived: a
# session removed under WTS_NO_ARCHIVE=1, or one whose archive store failed.
# A statement of its own, after the transaction that deletes the session: on a
# database an older wts created, the table may not exist yet, and with -bail
# that would abort the deletion itself.
usage_prune_sql() {
  print -r -- "DELETE FROM usage
  WHERE NOT EXISTS (SELECT 1 FROM sessions s
                    WHERE s.name = usage.session AND s.created_at = usage.created_at)
    AND NOT EXISTS (SELECT 1 FROM archive a
                    WHERE a.session = usage.session AND a.created_at = usage.created_at);"
}

# The seen rows of the sessions in <set> (a SQL list or subquery): those it
# holds as a reader, and those others hold on its notes and files. With `not`,
# of the sessions outside <set> (gc: whatever is no longer registered). Run
# after, never inside, the transaction that deletes the sessions, for the
# reason given at usage_prune_sql.
seen_prune_sql() {  # <set> [not]
  local op="IN"
  [[ "${2:-}" == not ]] && op="NOT IN"
  print -r -- "DELETE FROM seen
  WHERE session $op $1
     OR (stream IN ('notes', 'overlap')
         AND substr(ref, 1, instr(ref, char(31)) - 1) $op $1);"
}

# The status line's readings of the sessions in <set> (registry_del) or outside
# it (gc), as seen_prune_sql: a statement of its own, after the transaction,
# because a database an older wts left behind has no agent_gauges table.
gauges_prune_sql() {  # <set> [not]
  local op="IN"
  [[ "${2:-}" == not ]] && op="NOT IN"
  print -r -- "DELETE FROM agent_gauges WHERE session $op $1;"
}

# What the status line reported for each session, as one JSON object keyed by
# name: {context_pct, rate_limits: {five_hour, seven_day} | null,
# cost_reported_usd}, each null when no reading says. The newest row gives the
# gauges; the cost is the sum over the session's conversations. A row older
# than its session belongs to a former session of the same name.
gauges_json_sql() {
  print -r -- "SELECT json_group_object(s.name, json_object(
      'context_pct', g.context_pct,
      'rate_limits', CASE WHEN g.rate_5h IS NULL AND g.rate_7d IS NULL THEN NULL
                          ELSE json_object('five_hour', g.rate_5h, 'seven_day', g.rate_7d) END,
      'cost_reported_usd', (SELECT sum(c.cost_usd) FROM agent_gauges c
                            WHERE c.session = s.name
                              AND c.at >= CAST(strftime('%s', s.created_at) AS INTEGER))))
    FROM sessions s
    JOIN agent_gauges g ON g.rowid = (
      SELECT x.rowid FROM agent_gauges x
      WHERE x.session = s.name AND x.at >= CAST(strftime('%s', s.created_at) AS INTEGER)
      ORDER BY x.at DESC LIMIT 1)"
}

# What a task cost over every attempt, as a SQL expression yielding a JSON
# object ({tokens, cost_usd, cost_complete, sessions}) or NULL: the archived
# sessions that served it and the live ones linked to it now. <task> is a SQL
# literal (sql_str). wts task show prints it, wts log adds the same up itself.
task_usage_sql() {  # <task literal>
  local q="$1" cost
  cost=$(usage_cost_sql u)
  print -r -- "(SELECT CASE WHEN count(*) = 0 THEN NULL ELSE json_object(
      'tokens', sum(input + output + cache_write + cache_read),
      'cost_usd', round(coalesce(sum(cost), 0), 4),
      'cost_complete', json(CASE WHEN sum(model != '' AND cost IS NULL) > 0
                                 THEN 'false' ELSE 'true' END),
      'sessions', count(DISTINCT session || char(31) || created_at)) END
    FROM (SELECT u.*, $cost AS cost FROM usage u
          WHERE (u.session, u.created_at) IN (
            SELECT session, created_at FROM archive WHERE task = $q
            UNION SELECT s.name, s.created_at FROM sessions s
                  JOIN task_links l ON l.session = s.name WHERE l.task = $q)))"
}
