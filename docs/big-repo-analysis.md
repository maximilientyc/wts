# wts on a very large repository: UX and speed

Analysis of wts 0.2.1 on repositories far bigger than the ones it was written
against: hundreds of thousands of files, thousands of refs, a base branch that
moves by thousands of commits, many worktrees, a fat `node_modules`, big Claude
transcripts. Measured with `test/bench-big.zsh` (this branch), which generates
such a repository and times every command in a sandbox. The measurements and
the analysis are of 0.2.1 as released; every recommendation comes with the A/B
measurement that justifies it, and the last section shows the same bench after
the fixes this branch applies.

## Executive summary

On a 150k-file repository with 8 sessions (Apple M2 Pro, git 2.51):

| what | measured | verdict |
|---|---:|---|
| `wts ls`, `prefix+a`, one switcher tick | 12–13 s | unusable: `git status` scans every worktree every time (8 × 0.5–0.9 s), and a per-repository cache that never hits runs `branch --merged` over 3000 refs once per session (8 × 0.15–0.7 s) |
| `prefix+s`: list on screen / agent column filled | 0.04 s / **never** | the 2-second poller replaces the pass in flight; on a big repo the popup shows `-` forever |
| `wts gc` dry run, 3000 local branches | 921 s | `git cherry` per branch, 0.31 s each, with nothing on screen |
| `wts brief` for one session | 13 s | it runs the whole collector for all sessions first |
| `wts "<phrase>"`, `wts rm` | 11 s, 9–12 s | git's checkout and removal; wts adds ~1 s and no feedback |

Two settings the user can apply today, no wts change, measured on the same
worktrees: `core.fsmonitor=true` + `core.untrackedCache=true` take `git status`
from 0.5 s to 0.04 s per worktree and `wts ls` from 12.2 s to 2.6 s.

The fixes that matter most in wts itself, in order: a poller that never
preempts its own pass (the popup then fills in one tick instead of never), a
cheap collector mode for `prefix+a` and the switcher (agents and tmux only, no
git), the per-repository caches made to actually cache (a one-line subshell
bug, a third of the tick), one `jq` per pass instead of ten per session,
patch-ids of the base computed once in `gc` instead of once per branch, and
`brief` restricted to the sessions asked for. Each is quantified below.

## Method

`test/bench-big.zsh` builds a synthetic repository with `git fast-import`
(23 s for the large tier), in the same kind of sandbox as `test/smoke.zsh`:
private tmux server, private state and Claude directories, a stand-in `claude`
that reports agents in every state, no model call. It then creates sessions
through `wts` itself, makes them look like work in progress (two commits, three
modified files, two untracked files, an agent per session in rotation blocked /
working / idle, a 1 MB transcript, 10 MB for two of them), adds an ignored
`node_modules` to one worktree, an untracked `build/` tree to another, and a
husk folder next to them. Every command is timed (`EPOCHREALTIME`, median of 3
runs; the first run after a state change is the cold one), and a separate pass
with logging shims in front of `git`, `jq`, `tmux`, `claude` and `curl` counts
the processes each command spawns.

Tiers (files / commits / topic branches / commits origin is ahead by /
sessions):

| tier | files | commits | branches | origin ahead | sessions |
|---|---:|---:|---:|---:|---:|
| small | 1k | 200 | 100 | 50 | 3 |
| medium | 20k | 2000 | 1000 | 500 | 8 |
| large | 150k | 3000 | 3000 | 2000 | 8 |

Machine: Apple M2 Pro, 10 cores, 16 GB, APFS on the internal SSD,
`kern.maxvnodes` 250 752 (the default). git 2.51.2, tmux 3.7c, fzf 0.74.4, jq
1.8.2, tmuxinator 3.4.1, zsh 5.9. No fsmonitor unless stated. Half of the topic
branches point at an ancestor of main (merged by ancestry), half carry one
commit of their own (the squash-detection path of `wts gc`).

To replay: `make bench` (`TIER=small` for a one-minute sanity run), or
`zsh test/bench-big.zsh --tier large --sections "2 6" --out results.md` for a
subset. `WTS_BENCH_REPO=/path/to/monorepo` replays the battery on a real
repository: worktrees go to `<repo>-worktrees/` and are removed afterwards,
nothing else in that repository is written.

Caveats. The synthetic files are tiny and the history is uniform, so the
numbers flatter git's tree walks and packfile access: a real monorepo with big
blobs, deep directories and renames is slower in the same places, not faster.
The origin is a local bare clone, so every "network" figure is a floor. Cold
numbers are after the previous command, not after a reboot.

## Results

### Creating a session

| large tier | s |
|---|---:|
| `git worktree add` alone (150k files) | 10.8 |
| `wts <name> <layout>` | 11.4 |
| `wts "<phrase>"` with the slug taken twice (local slug, `WTS_NO_LLM`) | 11.4 |
| `wts-fresh <name>` (fetch, fast-forward of main by 2000 commits, then the above) | 14.0 |

`wts` spawns 7 git, 1 jq and 17 tmux processes on top of the checkout; its
overhead is about 0.6 s plus tmuxinator. The checkout is git's and shows git's
own `Updating files: NN%` progress, the only progress bar in the tool. The
uniqueness loop and the `ls-remote` against a local origin cost nothing
measurable; against a real remote they cost a round trip each, silently (see
"What the user sees").

### The collector

Everything that shows an agent state runs `libexec/wts/wts-status` once: `wts
ls`, `wts status`, `prefix+a`, every switcher tick, `wts gc`, `wts brief`.

| 8 sessions (3 at small) | small (1k files) | medium (20k) | large (150k) |
|---|---:|---:|---:|
| `wts ls` | 0.36 s | 2.3 s | 12.9 s (14.4 cold) |
| `wts status --json` | 0.35 s | 2.2 s | 12.1 s |
| `wts-status --fzf` (one switcher tick) | 0.34 s | 2.3 s | 12.2 s |
| `wts-switch --list-fast` (the skeleton drawn first) | 0.024 s | 0.039 s | 0.037 s |
| `wts-switch --next` (`prefix+a`) | 0.37 s | 2.3 s | 12.2 s |
| one TAB completion (`git worktree list --porcelain`) | 0.007 s | 0.008 s | 0.007 s |

The medium tier is the CHANGELOG's territory: 0.1.2 quoted 1.6–2.4 s for
`wts ls` on a 95k-file repository with 7 worktrees and fsmonitor on. The
numbers here are consistent with that (2.3 s at 20k files without fsmonitor,
1.4 s with), and show what happens past it: the tick grows with files ×
worktrees, and past the vnode cache it grows faster.

Processes per `wts ls` with 8 sessions: 56 git, 80 jq, 4 tmux, 1 claude (141).
Per worktree: `symbolic-ref`, `show-ref`, `rev-parse`, `status`, `rev-list`,
`diff`, `branch --merged`.

What each git call costs on one large worktree (with the collector's
`GIT_OPTIONAL_LOCKS=0`):

| per worktree | cold | warm |
|---|---:|---:|
| `status --porcelain` (`wts-status:177`) | 0.91 s | 0.50 s |
| same, worktree with an ignored `node_modules` of 50k files | 0.93 s | 0.50 s |
| same, worktree with an untracked `build/` of 50k files | 0.93 s | 0.50 s |
| `rev-list --left-right --count origin/main...HEAD` (`:181`) | 0.048 s | 0.023 s |
| `diff --shortstat origin/main...HEAD` (`:186`) | 0.024 s | 0.023 s |
| `branch --merged origin/main`, 3000 refs, once per pass (`:150`) | 0.74 s | 0.15 s |

The three per-worktree calls sum to 7.6 s over 8 worktrees; the pass takes
12.2 s. Two things make up the difference, both verified with an `xtrace`
profile of one pass on the medium tier.

The per-repository caches never hit. `merged_branches` (`wts-status:146-154`)
memoizes `git branch --merged` in an associative array, but it is called as
`$(merged_branches …)` (`:189`), inside a command substitution, so the
assignment happens in a subshell and is lost: the trace shows the git call
once per session, and the process count confirms it (8 `branch`, 8
`symbolic-ref`, 8 `show-ref` per pass for a single repository; `detect_base`
and `base_ref` are called the same way). With 3000 refs that is 8 × 0.15 s
warm, 8 × 0.74 s cold, per pass, for one boolean per session.

The rest is the cold side of `git status`: 8 worktrees × 150k files is 1.2 M
inodes, and macOS caches 250k vnodes by default (`kern.maxvnodes`, saturated
during the bench). Scanning the worktrees one after the other evicts each one
before it is scanned again, so the collector runs at the cold figure every
time, and `GIT_OPTIONAL_LOCKS=0` (`wts-status:33`) forbids git from writing the
refreshed index back, so its own stat cache never warms either.

Profile of one tick on the medium tier, 6 sessions, 1.5 s: `git status`
0.08–0.21 s × 6, `branch --merged` 0.055 s × 6, `rev-list` and `diff` 0.015 s
× 12, `capture-pane | shasum` 0.012 s × 2, and about 0.3 s of jq and process
starts spread over 700 traced lines.

### A/B: the same information, cheaper

Direct git calls on the same worktree, no wts code changed.

| `status` variant, large worktree | s |
|---|---:|
| `--porcelain`, `GIT_OPTIONAL_LOCKS=0` (what wts does) | 0.61 |
| `--porcelain`, locks allowed (index refreshed on disk) | 0.52 |
| `--porcelain --untracked-files=no` | 0.17 |
| `--porcelain=v2 --branch` (ahead/behind included) | 0.51 |
| `diff-index --name-only HEAD` + `ls-files -o --exclude-standard --directory` | 0.55 |
| `core.untrackedCache=true`, `GIT_OPTIONAL_LOCKS=0` | 0.52 |
| `core.untrackedCache=true`, locks allowed | 0.20 |
| `core.fsmonitor=true`, `GIT_OPTIONAL_LOCKS=0` | 0.048 |
| `core.fsmonitor=true`, locks allowed | 0.041 |
| `core.fsmonitor=true`, worktree with 50k untracked files | 0.54 |

| collector, 8 sessions | s |
|---|---:|
| `wts ls`, no fsmonitor | 12.2 |
| `wts ls`, fsmonitor + untrackedCache on, wts unchanged | 2.6 |
| `wts ls`, same, `GIT_OPTIONAL_LOCKS` unset in the collector | 2.6 |
| the 3 git calls × 8 worktrees, sequential | 8.0 |
| same, all worktrees in parallel (`&`/`wait`) | 6.5 |
| 56 jq processes (the collector's pattern for 8 sessions) | 0.21 |
| 1 jq process for the same questions | 0.007 |

Two things stand out. The untracked-file walk is 70 % of `git status`
(0.52 → 0.17 s without it), and the vnode cache is the rest: parallelism buys
little (8.0 → 6.5 s) because the walks are disk-bound, while fsmonitor removes
the walk (0.04 s). `GIT_OPTIONAL_LOCKS=0` costs nothing once fsmonitor answers,
and only 0.1 s without it: the lock avoidance introduced in 0.1.3 can stay.
untrackedCache alone helps only when the index can be written (0.20 s), which
the collector forbids.

Other A/Bs:

| | s |
|---|---:|
| `for-each-ref refs/heads` (3000 refs) | 0.07 |
| same with `%(upstream:track)` (`wts-gc:151`) | 0.12 |
| `wts-switch --preview` per cursor move (a zsh start + `capture-pane -S -2000`) | 0.011 |
| `tmux capture-pane -p -e -S -2000` alone | 0.004 |
| `wts-switch --fit` per cursor move | 0.010 |
| `zsh -c exit` (interpreter floor) | 0.003 |

The preview path is fine: 11 ms per cursor move, most of it zsh starting.

### wts gc

| large tier, 3000 local branches, origin/main 2000 commits ahead | s |
|---|---:|
| `wts gc --no-fetch` (dry run) | 921 |
| `git fetch --all --prune` (what plain `gc` adds; local origin) | 0.75 |
| per local branch | 0.31 |

| smaller tiers | s |
|---|---:|
| small, 100 branches: `wts gc --no-fetch` | 2.4 |
| small: processes, 233 git (103 `cherry`, 53 `rev-list`, 50 `reflog`), 34 jq | |
| medium, 1000 branches, origin 500 ahead: `wts gc --no-fetch` | 83 |
| medium: processes, 2073 git, 79 jq | |

Linear in the number of local branches: 0.024 s per branch at small,
0.083 s at medium, 0.31 s at large, the slope set by how far origin/main has
moved since the branches were cut.

Where the time goes, on one branch:

| | s |
|---|---:|
| `git cherry origin/main <branch cut 5000 commits back>` (`wts-gc:168`) | 0.37 |
| `git cherry origin/main <branch cut 3400 commits back>` | 0.27 |
| `rev-list --count origin/main..<branch>` (is the branch an ancestor?) | 0.021 |
| patch-id of every base commit since the merge-base, by hand | 1.40 |
| patch-id of the base commits touching the branch's paths only | 1.30 |
| `reflog show` without `-n` | 0.007 |
| `du -sk` on a 50k-file husk (dry run too, `wts-gc:250`) | 0.09 (0.22 cold) |
| `lsof -t` on one file (`wts-gc:438`) | 0.30 |
| `lsof -n -P -t` on one file | 0.10 |

`git cherry` is the whole story: it computes a patch-id for every commit on
both sides of the merge-base, and `gc` runs it for every local branch
(`wts-gc:268`), including the half that `branch --merged` (`:157`) already
reported as ancestors. Limiting the base side to the branch's paths does not
help (1.30 vs 1.40 s: git still walks the commits to filter them). Computing the
base's patch-ids once for all branches would.

### wts brief

| `WTS_NO_LLM` | medium | large |
|---|---:|---:|
| `wts brief` (8 sessions) | 4.1 s | 22.7 s |
| `wts brief bench-1` (one session, 10 MB transcript) | 2.4 s | 13.2 s |
| `wts brief bench-3` (one session, 1 MB transcript) | 2.1 s | 13.2 s |

| large tier | s |
|---|---:|
| 3 × `grep -F` over the 10 MB transcript (`wts-brief:83,137-139`) | 0.28 |
| 1 × `tail -c 2M | grep` (bounded) | 0.06 |
| `git diff HEAD --shortstat` on one worktree (`wts-brief:169`) | 0.18 |
| processes for 8 sessions: 104 git, 128 jq | |

`wts brief <one name>` costs 13 s because it starts with a full collector pass
over every session (`wts-brief:241`), then a second `git status` and a
`diff HEAD` per session on top (`:168-169`), all before the cache is consulted
(`:215`). With the model on, the 45-second calls come after that.

### Registry, restore, rm

| large tier | s |
|---|---:|
| `wts ls` with 5 stale registry entries (prune rewrites the file 5×) | 12.1 |
| `wts restore <name>` | 0.67 |
| `wts rm <name> -f`, plain worktree | 9.1 |
| `wts rm <name> -f`, worktree with 50k untracked files | 12.0 |
| `wts rm <name> -f`, worktree with an ignored 50k-file `node_modules` | 12.0 |

Registry operations are invisible next to the collector. `rm` is
`git worktree remove`; with `-f` it took the ignored `node_modules` away too.

## What the user sees, and when

Timeline of each command on the large tier, silence in bold. Nothing in wts
draws a spinner; every progress signal is a line printed before a blocking
call.

- **`wts "<phrase>"`**: `→ naming…`, up to 15 s of model call; then
  **silence** for `ls-remote --heads origin "<slug>*"` (`bin/wts:835`, bounded
  to 5 s) and, once the name is chosen, **silence again** for
  `ls-remote --exit-code --heads origin <branch>` (`bin/wts:879`, unbounded, on
  the common path of every new branch); then `→ creating worktree…` and git's
  `Updating files: NN%` for 11 s; then tmux takes over. On a local origin the
  two silences are 10 ms; on a real remote they are a round trip each, and the
  second one hangs for as long as the network does.
- **`prefix+:` then `wts …`** (`wts-fresh`): `→ fetch origin/main`, then
  **silence** for the fetch (`--quiet`, no timeout, `wts-fresh:204`) and for
  the fast-forward of the main worktree (a `git status --untracked-files=no`
  and a `merge --ff-only` that rewrote the files of 2000 commits here,
  `:266,272`); then the creation above. 14 s total on a local origin.
- **`prefix+s`**: the skeleton list is on screen in 0.5 s (the list itself
  takes 40 ms; the rest is fzf and tmux starting), with `-` in the AGENT and
  DELTA columns and fzf's spinner. Then, on the large tier, **it stays that
  way**: the first collector pass needs 12 s, the poller sends a `reload-sync`
  every 2 s (`wts-switch:731`), and fzf drops the reload in flight when the
  next arrives. In 60 s, 36 passes were started and none finished (287 git
  and 424 jq processes for nothing). The user sees a list of names with no
  state, a spinner that never stops, and a `prefix+a` that does nothing
  useful. With `WTS_SWITCH_REFRESH=60` the same popup fills after 12.15 s,
  one tick (section 6 of the bench).
- **`prefix+a`**: **12 s of nothing**, then the jump (or the "no agent
  waiting" message).
- **`wts ls`**: **13 s of nothing**, then the table.
- **`wts brief`**: **23 s of nothing** (collector + facts), then
  `→ summarizing N session(s) with Claude…`, then the model calls in batches of
  4 with a 45 s timeout each.
- **`wts gc`**: the header and `Remote: …` lines at once, then **15 minutes of
  nothing** while 3000 branches go through `git cherry`, then the report.
  With the fetch, add the remote's round trip in the same silence.
- **`wts rm <name>`**: **9–12 s of nothing** while git removes 150k files,
  then `→ worktree … removed`.
- **TAB completion, `wts restore`, `wts stop`, `wts layouts`**: instant.

## Root causes, ranked

1. **The collector scans every worktree's whole tree, every time.**
   `git status --porcelain` (`libexec/wts/wts-status:177`) walks the tracked
   files and the untracked ones of each registered worktree, sequentially, on
   every `wts ls`, every `prefix+a`, every switcher tick, and inside `gc` and
   `brief`. 0.5 s warm, 0.9 s cold per 150k-file worktree; cold is the normal
   case once worktrees × files exceeds the vnode cache. Nothing is cached
   between passes (the in-process caches at `:91` die with the process), and
   `GIT_OPTIONAL_LOCKS=0` (`:33`) keeps git's own cache from warming.
   Measured: 60–75 % of a 12 s pass. With fsmonitor: 2.6 s.
2. **The switcher's poller preempts its own pass.** `reload-sync` every
   `WTS_SWITCH_REFRESH` (2 s) seconds (`wts-switch:726-736`), no in-flight
   guard, no adaptation to the tick's duration; documented as "the poller
   replaces the one in flight" at `wts-status:24-26`. Whenever a pass takes
   longer than the interval, the columns never fill. Measured: 0 of 36 passes
   completed in 60 s at the large tier, 12.15 s to fill once the poller is
   kept out of the way; 1 s to fill at the small tier.
3. **`gc` runs `git cherry` once per local branch, for every local branch.**
   `wts-gc:268` iterates `refs/heads/`, `:168` pays the patch-ids of the base
   side (5000 commits here) again for each branch, including the ones
   `branch --merged` already settled. 0.31 s × 3000 = 921 s, with no output
   in between.
4. **`brief` does the whole collector's work, then does it again.** A full
   `wts-status --json` for every session even when one name is asked
   (`wts-brief:241`), a second `git status` and a `diff HEAD --shortstat`
   per session (`:168-169`), three full-file greps per transcript (`:83`,
   `:137-139`), all before the cache key is computed (`:215`). 13 s for one
   session.
5. **`prefix+a` pays for columns it does not show.** `wts-switch:552` runs
   the full collector to learn which agents are blocked, an answer that
   `claude agents --json` and `tmux list-sessions` give in 50 ms.
6. **One process per question.** ~10 `jq` per session (`wts-status:199-253`),
   one of them re-parsing the whole agents array per worktree; 141 processes
   per `wts ls` with 8 sessions, 237 per `wts brief`. 0.2 s at 8 sessions,
   linear in sessions; a floor even after the git fixes.
7. **No feedback where the tool waits.** `ls-remote` on the common create
   path (`bin/wts:879`) has no timeout and no message; both fetches are
   `--quiet` (`wts-fresh:204`, `wts-gc:92`); `wts ls`, `prefix+a`, `wts rm`,
   `wts brief` print nothing until they are done; `gc` prints nothing during
   its analysis. The only progress bar the user ever sees is git's checkout.
8. **The per-repository caches are dead code.** `merged_branches`,
   `detect_base` and the base-ref lookup memoize into associative arrays
   (`wts-status:91-154`) but are called inside `$(…)` (`:189` and the two
   calls before it), so the memo is written in a subshell and lost.
   `git branch --merged` over 3000 refs therefore runs once per session:
   8 × 0.15 s warm, 8 × 0.74 s cold, per pass, for one boolean per session.
   This is a third of the tick on the large tier.
9. **Small things that add up in `gc`**: `lsof` without `-n -P` (0.3 s vs
   0.1 s per lock candidate, `wts-gc:438`), `du -sk` on every husk in the dry
   run (`:250`), `%(upstream:track)` in the ref enumeration (`:151`, 0.12 vs
   0.07 s), `reflog show` without `-n` (`:191`, negligible here).

Not a problem, measured: the skeleton list (40 ms), TAB completion (8 ms),
the preview per cursor move (11 ms), the registry file (a few jq calls on a
small JSON), `wts restore` (0.7 s), the creation overhead on top of git's
checkout (0.6 s).

## Recommendations

Ranked by measured gain over effort. The gain column is what the A/B tables
above show, on the large tier with 8 sessions.

### In wts

1. **Never preempt a collector pass** (`wts-switch:726-736`). Skip the tick
   while a `reload-sync` is running, and schedule the next one at
   `max(WTS_SWITCH_REFRESH, last pass duration)` after it ends. Gain: the popup
   fills after one tick (12 s here, 2.6 s with fsmonitor) instead of never.
   Effort: small; the poller already owns the timing loop.
2. **A cheap collector mode for what only needs agents and tmux.**
   `wts-status --no-git` (or a `WTS_STATUS_GIT=0` env) that skips `:177-190`
   and fills DIRTY/DELTA with `-`: used by `prefix+a` (`wts-switch:552`) and
   by the switcher's first fill, with the git columns arriving in a second
   pass. Gain: `prefix+a` 12 s → ~0.1 s; the popup shows agent states in
   under a second whatever the repository. Effort: small; the JSON contract
   already allows `-` columns ("degrade, don't die").
3. **Enable, or advise, fsmonitor and untrackedCache.** `core.fsmonitor=true`
   + `core.untrackedCache=true` on the repository: `git status` 0.5 → 0.04 s,
   `wts ls` 12.2 → 2.6 s, no wts change. wts cannot set it silently (it is a
   repository-wide setting the user may not want), but it can print a one-line
   hint the first time a pass exceeds a few seconds, document it in the README
   next to `WTS_SUBDIR`, and offer `wts setup git` that prints the two config
   lines like `wts setup tmux` does. `GIT_OPTIONAL_LOCKS=0` can stay: it
   costs nothing once fsmonitor answers.
4. **One `jq` per pass.** Emit one `\x1f`-separated line per session from the
   shell loop, and let a single `jq -R` at the end build the objects and join
   the agents array (`wts-status:199-253`). Gain: 0.2 s at 8 sessions, more
   with more sessions; also removes the O(sessions²) re-parsing of
   `claude agents --json`. Effort: medium, contained in one file; the
   `--json` contract does not change.
5. **`gc`: patch-ids of the base once, not once per branch.** Compute the
   merge-base of every candidate branch, take the oldest, run
   `git rev-list origin/main ^<oldest> | git diff-tree --stdin -p | git patch-id --stable`
   once (1.4 s for 5000 commits here) into a set, then per branch compute the
   patch-ids of its own commits only (a handful) and look them up. Skip the
   branches `branch --merged` already reported (half of them here). Gain:
   921 s → on the order of 10–30 s for 3000 branches. Effort: medium; the
   squash rule stays exactly the same. Also worth it: print a progress line
   every N branches, and consider scoping the branch loop to branches with a
   worktree, a registry entry or the layout's branch prefix unless `--all`.
6. **`brief`: collect only the sessions asked for, and reuse what the
   collector knows.** Filter the registry before the collector runs
   (`wts-brief:241`), take `dirty` and the porcelain hash from the collector's
   JSON instead of a second `git status` (`:168`), drop or bound
   `diff HEAD --shortstat` (`:169`, 0.18 s per session for a number the model
   barely uses), and replace the three whole-file greps with one bounded
   `tail -c` pass (`:83`; 0.28 → 0.06 s per 10 MB). Gain:
   `wts brief <name>` 13 s → about the cost of one collector entry.
7. **Say what is happening, and bound what waits on the network.** Print
   `→ checking origin for <branch>` before `bin/wts:879` and put it under the
   same 5-second `perl alarm` as `:835` (a timeout means "assume new branch",
   which is what a fetch failure means today); drop `--quiet` from the two
   fetches when stderr is a terminal so git's own progress shows; print
   `→ removing worktree…` before `git worktree remove`; print
   `→ collecting N sessions…` on stderr in `wts ls` and `wts brief` when
   stderr is a terminal; print one line per 100 branches in `gc`. Effort:
   small, all one-line additions.
8. **Make the per-repository caches actually cache.** Call `merged_branches`,
   `detect_base` and the base-ref lookup without a command substitution (have
   them set a variable, or test the cache in the caller), so the memo survives
   (`wts-status:189` and the two calls before it). Gain: 7 of the 8
   `branch --merged` calls per pass, 1–5 s on the large tier, plus 14 small
   git calls. Effort: trivial; a smoke assertion on the process count would
   keep it fixed. Persisting the merged list across passes (keyed on the base
   SHA and the `refs/heads` mtime) would save the last call too.
9. **`gc` details**: `lsof -n -P -t` (`wts-gc:438`, 3× faster), skip `du` in
   the dry run or cap it, `for-each-ref` without `%(upstream:track)` where
   the tracking state is not used (`:151`), `reflog show -n 50` (`:191`).

Not recommended: `--untracked-files=no` in the collector (3× faster, but the
DIRTY column would stop counting new files, which is the column's point);
parallel `git status` across worktrees (8.0 → 6.5 s only, disk-bound, and it
multiplies the vnode pressure); dropping `GIT_OPTIONAL_LOCKS=0` (0.1 s gain,
brings back the `index.lock` collisions of 0.1.3).

### In the repository, documented rather than automated

- `core.fsmonitor=true` and `core.untrackedCache=true` (above). Worth a README
  section titled "Large repositories".
- `kern.maxvnodes`: when worktrees × tracked files exceeds it (250k by default
  on macOS), every scan is cold. `sudo sysctl kern.maxvnodes=1000000` is the
  blunt fix; fsmonitor is the better one.
- Sparse checkout for monorepos: wts creates full worktrees (`bin/wts:892`),
  10.8 s and 600 MB each here, and `wts rm` pays the same to delete them. A
  `WTS_SPARSE=<cone dirs>` that does `worktree add --no-checkout`,
  `sparse-checkout set`, `checkout` would make creation proportional to the
  cone. Effort: medium; only worth it if the user's monorepo is one.

## After the fixes

The recommendations 1, 2, 4, 5, 6, 7 and 8 above, plus `wts setup git` and
the `lsof` flags, are applied on this branch. Same bench, same large tier,
before and after:

| large tier, 8 sessions | before | after |
|---|---:|---:|
| `wts ls` (median) | 12.9 s | 10.0 s |
| one collector tick | 12.2 s | 9.4 s |
| processes per `wts ls` | 141 (56 git, 80 jq) | 80 (35 git, 40 jq) |
| `prefix+a` | 12.2 s | 0.25 s |
| `prefix+s`: agent states on screen | never | 1.0 s |
| `prefix+s`: git columns on screen | never | 12.4 s (one pass after the 2 s tick) |
| `wts brief <one session>` | 13.2 s | 1.7 s |
| `wts brief` (8 sessions) | 22.7 s | 18.5 s |
| `wts gc --no-fetch`, 3000 branches | 921 s | 337 s |
| `wts gc --no-fetch`, medium tier, 1000 branches, same sandbox, old vs new | 85 s | 19 s (11 s with a commit-graph); identical verdicts |
| `wts rm`, `wts <name>` | 9–12 s, 11 s | unchanged: git's own removal and checkout, now announced |

What remains in the tick is `git status` walking eight 150k-file trees that
no longer fit the vnode cache (7.8 s of the 9.4 s): that is the repository
setting `wts setup git` prints, not a wts change. With it, the same tick
measured 2.6 s before the fixes and would be under 2 s after them.

What remains in `gc` is one `rev-list` per branch (which commits are its own)
and, for the branches merged by ancestry, the `rev-list --count` and `reflog`
of the new-branch test: 1559 git processes for 1000 branches, 0.02 s each on
this history without a commit-graph, half that with one (`git commit-graph
write --reachable`, which git's own gc maintains on a real clone).

## Not measured here

- A slow or unreachable remote. Three calls have no timeout and print nothing
  while they wait: `git ls-remote --exit-code --heads origin <branch>` in the
  create flow (`bin/wts:879`), the fetch in `wts-fresh` (`:204`), and
  `git fetch --all --prune --quiet` in `wts gc` (`:92`). The bench's origin is
  a local bare clone; on a VPN or a flaky link these are the moments the tool
  hangs with a blank screen.
- A real monorepo, with big blobs, renames and deep trees:
  `WTS_BENCH_REPO=<path>` replays the whole battery on one.
- `claude agents --json` on a machine running many agents: called once per
  collector pass, no timeout (`wts-status:65`).
- The model calls of `wts "<phrase>"` and `wts brief`: bounded by
  `WTS_NAME_TIMEOUT` (15 s) and `WTS_BRIEF_TIMEOUT` (45 s), unchanged by
  repository size.
