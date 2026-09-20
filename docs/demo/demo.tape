# The README demo. Run it through docs/demo/record.zsh (`make demo`), which
# builds the sandbox this tape expects: a clone in ./wts, two documents in the
# library, four sessions with their agents blocked, working and idle, and a
# squash-merged branch. Needs fzf 0.45 or newer for the reply step (tab), and
# 0.65 or newer for the key table (?).
#
# One morning with four agents: a document put in the library, a session started
# from a sentence, the agent that is blocked answered, another handed the
# document while it works, a finished one stopped and then brought back, and the
# merged branch collected.
#
# Rows in the popup are reached by typing a filter, never with Down: the list
# re-sorts by urgency every WTS_SWITCH_REFRESH seconds, so a row moves under the
# cursor as soon as the agent it shows changes state.
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

# Your own prompt instead of VHS's.
Hide
Type "exec zsh -l"
Enter
Sleep 2s
Type "cd wts && clear"
Enter
Sleep 1s
Show

# 1. The document every agent on this repository needs, put in the library
# once. A file here, a Notion page or any URL elsewhere; the slug is what
# --doc asks for afterwards.
Sleep 1s
Type "wts doc add CLAUDE.md --name conventions"
Sleep 500ms
Enter
Sleep 3s

# 2. A session from a sentence, with that document attached: Haiku names it,
# wts writes .wts/context.md and the agent opens on it. tmux opens on nvim and
# the agent starting on the task.
Type `wts "add a --json flag to wts brief" --doc conventions`
Sleep 700ms
Enter
Sleep 1s
# Hidden well past the wait: your nvim's startup notifications fade out
# off-camera. Ten seconds, not three — a plugin that fails to start (a Copilot
# client quitting) notifies several seconds after nvim is up, and its popup
# then sits over the editor in the one frame this demo is about.
Hide
Wait+Screen@60s /Sonnet|Opus|Haiku/
Sleep 10s
Show
Sleep 4s

# 3. Somewhere else an agent is stuck on a question. prefix+a goes straight to
# it: the engine already sorts blocked first, so no list is needed to find it.
Ctrl+B
Type "a"
Sleep 4s

# 4. The switcher: everyone at once, whoever needs you first, with a live
# preview of the agent's pane. `?` unfolds everything the popup can do.
Ctrl+B
Type "s"
Wait+Screen@20s /blocked/
Sleep 2500ms
Type "?"
Sleep 3s
Type "?"
Sleep 1s

# 5. The blocked agent asked a numbered question: tab pins the row, "1" and
# enter answer from the popup, and the preview shows the agent going on.
Tab
Sleep 1500ms
Type "1"
Sleep 800ms
Enter
Sleep 5s
Escape
Sleep 1500ms

# 6. The agent next door has been working without the conventions: ctrl-e
# attaches the document to a session already running, and types the reference
# into its pane — no restart, no re-pasting.
#
# The picker ctrl-e opens is the numbered one, not the fzf one: under fzf's
# `execute` stdout is not a tty (stdin and stderr are), so pick_doc's
# `-t 0 && -t 1` test fails and it degrades rather than give up. "2" is the
# conventions document: record.zsh seeds big-repo first, scene 1 appends it.
Type "stale"
Sleep 1s
Ctrl+E
Sleep 2500ms
Type "2"
Sleep 1s
Enter
Sleep 4s
Enter
Sleep 2500ms

# 7. name-fallback's one-line job is done: ctrl-x stops the session and keeps
# the worktree. The row reads "stopped".
Ctrl+U
Type "name"
Sleep 1s
Ctrl+X
Wait+Screen@10s /Kill tmux session/
Sleep 2s
Type "y"
Sleep 3s
Ctrl+U
Sleep 1s
Escape
Sleep 1500ms

# 8. The session's shell window: state of every session, then where each one
# stands.
Ctrl+B
Type "n"
Sleep 1s
Type "wts ls"
Sleep 500ms
Enter
Wait+Line@30s /❯$/
Sleep 4s
# Not Ctrl+L: vim-tmux-navigator binds it to pane navigation.
Hide
Type "clear"
Enter
Sleep 500ms
Show
Type "wts brief"
Sleep 500ms
Enter
Sleep 1500ms
Hide
Wait+Line@180s /❯$/
Show
Sleep 6s

# 9. Second thoughts about the one that was stopped: restore replays it from
# the registry, with `claude --continue` pre-filled in its pane. The same
# command is what brings all of them back after a reboot.
Hide
Type "clear"
Enter
Sleep 500ms
Show
Type "wts restore"
Sleep 500ms
Enter
Wait+Line@60s /❯$/
Sleep 4s

# 10. Cleanup: the squash-merged branch goes, busy sessions stay.
Hide
Type "clear"
Enter
Sleep 500ms
Show
Type "wts gc --apply"
Sleep 500ms
Enter
Wait+Line@60s /❯$/
Sleep 5s
