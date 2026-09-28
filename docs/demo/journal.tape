# The work journal. Run it through docs/demo/record.zsh with
#   WTS_DEMO_TAPE=docs/demo/journal.tape WTS_DEMO_OUT=docs/journal.gif
# which builds the sandbox this tape expects: a clone in ./wts, four sessions
# with their agents blocked, working and idle, and `orig-leftovers` squash-merged
# into the base with its remote branch deleted — the case `wts gc` exists for.
#
# What it shows: a session labelled with the task it serves, then `wts gc --apply`
# tearing that session down and, for the first time, keeping something — the
# facts, and a retrospective written while the transcript still exists. Then the
# two views on what was kept: `wts task ls` and `wts log`.
#
# WTS_NO_THINGS is set in the preamble on purpose. `wts log` reads the real
# Things 3 database of whoever records this, and their task titles have no place
# in a GIF that ends up in a README.
#
# Waits on the prompt use /❯$/, the line the cursor is on: your zsh prompt
# (powerlevel10k) ends with that character when the command has returned.

Output raw.gif

Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 14
Set Width 1400
Set Height 800
Set Padding 20
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 45ms

# Your own prompt instead of VHS's, and no Things for the whole take.
Hide
Type "exec zsh -l"
Enter
Sleep 2s
Type "cd wts && export WTS_NO_THINGS=1 && clear"
Enter
Sleep 1s
Show

# 1. Four sessions, one per agent. `orig-leftovers` is the one whose branch has
# landed: its work is finished, and everything about it is about to be deleted.
Sleep 1s
Type "wts ls"
Sleep 500ms
Enter
Sleep 4s

# 2. The task it serves. A local one here, so the tape needs no Things; from
# Things it is `wts task link` on a real task, and its notes bring their Notion
# pages and Slack threads along as context documents.
Type `TASK=$(wts task new "Ignore *.orig merge leftovers")`
Sleep 500ms
Enter
Sleep 1s
Type `wts task link $TASK orig-leftovers`
Sleep 500ms
Enter
Sleep 3s

# 3. One character in the SUBJECT column, and that is all the daily UI says
# about it: the switcher has to stay one flat, scannable list.
Type "wts ls"
Sleep 500ms
Enter
Sleep 4s

# 4. The dry run says what it would keep, and still writes nothing.
Type "wts gc"
Sleep 500ms
Enter
Sleep 7s

# 5. The same command for real. It kills the session, removes the worktree,
# deletes the branch — and before any of that, collects the facts the worktree
# holds; then, after all of it, asks Haiku for four lines. Last on purpose: a
# timeout there costs only text, which `wts retro` rewrites later.
Type "wts gc --apply"
Sleep 500ms
Enter
Sleep 45s

# 6. What survived the teardown, grouped by the task rather than by branch.
Type "wts task ls"
Sleep 500ms
Enter
Sleep 6s

# 7. And the corpus itself: the same row as JSON, which is what a review is
# written from six months later, when the branch and the transcript are gone.
Type `wts log --brief | jq '[.work[].sessions[] | select(.state == "archived")][0] | {branch, outcome, diff, retro}'`
Sleep 500ms
Enter
Sleep 9s

Sleep 2s
