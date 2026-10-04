# Upgrading to 1.0

1.0 moves all of wts's state from files to one SQLite database. Nothing to do by
hand beyond upgrading, but here is what happens and how to check it. Later
releases are in [CHANGELOG.md](../CHANGELOG.md).

1. **Upgrade**: `brew update && brew upgrade wts` (or `git pull && make
   install`). `wts --version` prints `wts 1.0.0`. `sqlite3` must be on the
   `PATH`: macOS ships it.
2. **Optional backup**: `cp -R ~/.local/state/wts ~/.local/state/wts.bak-0.x`
   (or under your `XDG_STATE_HOME`).
3. **Run any wts command**: `wts ls` will do. The first one imports the old
   state into `wts.db` and says so:
   `→ state imported into …/wts/wts.db (8 sessions; old file kept as sessions.json.migrated)`.
   Imported: the registry (`sessions.json`) and the fetched documents
   (`docs/*.md`). Dropped, and rebuilt on first use: the `wts brief` cache
   (`brief/`) and the stale guard's pane hashes (`panehash/`).
4. **Check**: `wts ls` lists the same sessions as before, and
   `wts db sql "select count(*) from sessions"` gives their number.
5. **Let the agents see each other**: `wts setup claude`, read it, then
   `wts setup claude --install`. Agents already running pick it up at their
   next `/clear`, `/compact` or restart.
6. **Scripts** that read `sessions.json` directly: switch to
   `wts status --json` (unchanged contract) or `wts db sql "…" --json`.

**Rolling back** to 0.4.3: reinstall it, then
`mv ~/.local/state/wts/sessions.json.migrated ~/.local/state/wts/sessions.json`.
Sessions created under 1.0 are missing from that file (their worktrees and
branches are untouched; `wts <name>` in the repository registers one again).

The single database also fixes a lost update the old JSON file allowed: a
second writer now waits its turn instead of overwriting the first.
