# Cleaning up: `wts gc`

`wts gc` removes what finished work leaves behind: worktrees and branches whose
content is in the base (merged by squash and rebase included), folders
`git worktree remove` left, registry entries without a worktree, and stale
`index.lock` files. It only touches what wts made, and does nothing
until you pass `--apply`.

```
wts gc [--all] [--all-branches] [--apply] [--no-fetch] [--no-retro]
wts gc [--all] [--all-branches] [--no-fetch] --json
wts rm <name> [-f]
```

## Usage

```sh
wts gc                  # dry run: lists, deletes nothing
wts gc --apply          # does it
wts gc --no-fetch       # without contacting the remote (offline)
wts gc --all            # every repository that has a session, from anywhere
wts gc --all-branches   # every local branch, not only those of wts sessions
wts gc --json           # the dry run's plan: what would go and why
```

- `wts gc` acts on the repository of the current directory. `--all` runs the
  same collection once per repository in the registry, each from its main
  worktree.
- `--json` describes the dry run; it is never accepted with `--apply`.

**What `--apply` costs is said before it.** Each session it archives gets a
retrospective, one model call each (`WTS_RETRO_MODEL`, `WTS_RETRO_JOBS` at a
time, after every deletion). The dry run says how many, and `--no-retro` skips them;
`wts retro` writes them later ([journal.md](journal.md)).

**A dry run writes nothing.** It announces `To archive (kept for wts log): 3
session(s)` and stops there.

## Scope: only what wts made

- A branch is looked at when a session of this repository had it: a live one,
  or a finished one in the archive.
- A husk folder is looked at when it bears such a session's name.
- A local `develop` you merged by hand, a worktree you made yourself, a folder
  someone else keeps under a shared `WTS_WORKTREES_BASE`: the dry run counts
  them ("not made by a wts session, not looked at: 3") and leaves them alone.
- `--all-branches` widens the scope to every local branch and every folder
  without `.git`, for a repository where all of them are disposable.

## The six categories

`wts gc` starts with `git fetch --all --prune`, then compares against
`origin/<base>` rather than a local base that may lag behind: **the remote is
the source of truth**.

1. **Husk folders** in `<repo>-worktrees/`: `git worktree remove` leaves
   git-ignored files behind, so a folder without `.git` remains after each
   `wts rm`.
2. **Worktrees on a dead branch**: removed with their tmux session and branch.
3. **Dead branches** without a worktree: their content is entirely in the base.
4. **Orphan branches**: the remote branch is gone but the content is **not** in
   the base. Never deleted automatically: listed with their commit count, your
   call.
5. **Orphan registry entries** whose worktree disappeared.
6. **Stale `index.lock`**: a git process killed mid-operation leaves one
   behind, and from then on every write in that worktree fails with `Unable to
   create '.git/worktrees/<session>/index.lock': File exists`. Nothing reports
   it, so the worktree looks fine until the next `git add`.

With `--apply`, what it tears down is archived for the [work
journal](journal.md), and the agents of the other sessions are told the session
finished ([agents.md](agents.md#the-news-during-a-session)).

## Safety rules

- Only `<repo>-worktrees/` is scanned for husks, and a folder with a `.git` is
  never proposed.
- A branch with no commit since it was created is never collected: a fresh
  session whose agent has not committed yet looks "merged" to git.
- A worktree with uncommitted changes, or whose agent is busy (`working`,
  `blocked`, `stuck?`), is left in place and listed as such.
- The current tmux session is never killed.
- An `index.lock` is only removed once it is empty, older than
  `WTS_LOCK_STALE_AFTER` (5 min) and held by no live process: deleting a lock
  somebody owns would corrupt their index.

## `wts rm` and a merged branch

`wts rm` without `-f` deletes a branch merged by squash or rebase, which
`git branch -d` refuses, and archives the session as `squashed` or `merged`.
The rest of what `wts rm` does is in [sessions.md](sessions.md#removing-a-session).

## How a merged branch is recognized

**Why not `git branch --merged`.** It only recognizes merges by ancestry. A
pull request merged by **squash** or **rebase** rewrites the SHAs, so the branch
is never an ancestor of the base and piles up forever.

`wts gc` counts a branch as merged, and deletes it with `git branch -D`, when
any of these holds:

1. **Patch-ids.** Every commit of the branch has an equivalent in the base: it
   is entirely present in it, whatever the merge method. This is the test behind
   `git cherry`, with the base hashed once for all branches rather than once per
   branch.
2. **Merge-tree.** A squash of several commits lands as one diff that matches
   none of them, so a branch also counts when merging it into the base would
   change nothing (`git merge-tree`, git 2.38+).
3. **The pull request.** gh saw its pull request merged with the branch's
   current tip as its head.

The last witness is what survives a release: the release rewrites the CHANGELOG
lines and the version a squash landed, the merge conflicts, and only the pull
request still says it merged. So after its fetch, `wts gc` asks gh itself, one
`gh pr list --state merged` per repository, for the branches every other test
left unmerged, and writes what it learns to `pr_state`.

- Not with `--no-fetch`, and silently not without gh or a GitHub remote.
- `WTS_GC_GH_TIMEOUT` (20 s) bounds the call.

A deleted remote branch is read from `%(upstream:track)` == `[gone]`, which
only `--prune` reveals.
