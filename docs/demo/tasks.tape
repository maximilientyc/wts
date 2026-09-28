# The task as the place context lives. Run it through docs/demo/record.zsh with
#   WTS_DEMO_TAPE=docs/demo/tasks.tape WTS_DEMO_OUT=docs/tasks.gif \
#   WTS_DEMO_BIN=$PWD/bin WTS_DEMO_READY='[.[]] | any(. == "working" or . == "blocked" or . == "idle")' \
#   zsh docs/demo/record.zsh
# which builds the sandbox this tape expects: a clone in ./wts and a few sessions
# with live agents, so the switcher shows real work above the task.
#
# WTS_DEMO_BIN is not optional here. The tmux bindings in your ~/.tmux.conf hold
# an ABSOLUTE path to the installed wts-switch, so prefix+s would open the
# released switcher, which knows nothing about tasks. The preamble re-sources
# `wts setup tmux` from the checkout into the sandbox server — private, so your
# own bindings are untouched — and that only finds the checkout's wts because
# WTS_DEMO_BIN put it first on PATH.
#
# What it shows: a task given its context once (a note, a document), then the
# switcher — where that task is a row under the sessions, with how much context
# it carries — a note typed onto it without leaving the popup, and `enter`
# turning it into a session whose agent opens on all of it.
#
# WTS_NO_THINGS is set in the preamble on purpose, as in journal.tape: `wts task`
# reads the real Things 3 database of whoever records this, and their task titles
# have no place in a GIF that ends up in a README. It costs the tape ctrl-t,
# which is the one key of this feature the GIF cannot show.
#
# The filter is retyped before `enter` in scene 5 on purpose: leaving note mode
# clears the query, the full list comes back, and fzf keeps the cursor by INDEX —
# so the highlighted row after `escape` is not necessarily the task any more.
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

# Your own prompt instead of VHS's, no Things for the whole take, and prefix+s
# bound to THIS checkout on the sandbox server only.
Hide
Type "exec zsh -l"
Enter
Sleep 2s
Type "cd wts && export WTS_NO_THINGS=1"
Enter
Sleep 1s
Type "wts setup tmux > /tmp/wts-demo/dev.tmux && tmux source-file /tmp/wts-demo/dev.tmux && clear"
Enter
Sleep 1s
Show

# 1. A task, and the two things that make it worth having: a note in your own
# words, and a document every session on it should open with. Both belong to the
# task, not to a session — so they outlive the branch that gets merged.
Sleep 1s
Type `TASK=$(wts task new "Ship the audit trail")`
Sleep 500ms
Enter
Sleep 1500ms
Type `wts task note $TASK "the ledger must stay append-only"`
Sleep 500ms
Enter
Sleep 2s
Type "wts doc add CLAUDE.md --name conventions"
Sleep 500ms
Enter
Sleep 3s
Type `wts task doc $TASK conventions`
Sleep 500ms
Enter
Sleep 3s

# 2. What the task carries now. This is what a session started on it inherits.
Type "clear && wts task show $TASK"
Sleep 500ms
Enter
Wait+Line@20s /❯$/
Sleep 5s

# 3. The switcher, the view that gets used: the agents at work first, and under
# them the work not started yet. `2 ctx` is the count of what that task carries —
# enough to tell, at a glance, whether it is ready to be picked up.
Ctrl+B
Type "s"
Wait+Screen@20s /task/
Sleep 4s

# 4. Filtering to it makes the preview the task itself: its status, the note, the
# document. A row is reached by typing, never with Down — the list re-sorts by
# urgency every WTS_SWITCH_REFRESH seconds.
Type "audit"
Sleep 3s

# 5. tab turns the query line into an input for the task, the way it does for an
# agent, and enter appends the line to its notes. The count in DELTA moves.
Tab
Sleep 1500ms
Type "finance wants the CSV export in the same PR"
Sleep 500ms
Enter
Sleep 4s
Escape
Sleep 2s

# 6. And enter on the task starts a session on it. The popup closes and tmux's
# command prompt opens pre-filled — the name proposed from the title, still
# editable, and the branch still cut from a freshly fetched base because this
# goes through the same `wts` command as prefix+g.
Type "audit"
Sleep 1500ms
Enter
Sleep 4s
Enter
Sleep 1s
# Hidden past the wait, as in demo.tape: your nvim's startup notifications fade
# out off-camera rather than sitting over the frame this demo is about.
Hide
Wait+Screen@90s /Sonnet|Opus|Haiku/
Sleep 10s
Show

# 7. The payoff: the agent opened on .wts/context.md, whose first section is the
# task — its title, its status, the note typed in the popup a moment ago, and the
# document. Nothing was pasted into it.
Sleep 8s
