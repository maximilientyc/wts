# The README demo. Run it through docs/demo/record.zsh (`make demo`), which
# builds the sandbox this tape expects: a clone in ./wts, four sessions with
# their agents blocked, working and idle, and a squash-merged branch. Needs
# fzf 0.45 or newer for the reply step (tab).
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

# 1. A session from a sentence: Haiku names it, then tmux opens on nvim and
# the agent starting on the task.
Sleep 1s
Type `wts "add a --json flag to wts brief"`
Sleep 700ms
Enter
Sleep 1s
# Hidden a little longer than the wait: your nvim's startup notifications
# fade out off-camera.
Hide
Wait+Screen@60s /Sonnet|Opus|Haiku/
Sleep 3s
Show
Sleep 4s

# 2. The switcher: whoever needs you comes first, with a live preview of its
# pane. gc-quiet is blocked on a numbered question: tab pins it, "1" + enter
# answers from the popup and the preview shows the agent going on. Then
# name-fallback, whose one-line job is done, is stopped with ctrl-x: the row
# reads "stopped", the worktree stays.
Ctrl+B
Type "s"
Wait+Screen@20s /blocked/
Sleep 2500ms
Down
Sleep 1500ms
Down
Sleep 1500ms
Up
Sleep 1s
Up
Sleep 1s
Tab
Sleep 1500ms
Type "1"
Sleep 800ms
Enter
Sleep 6s
Escape
Sleep 1500ms
Type "name"
Sleep 1s
Ctrl+X
Wait+Screen@10s /Kill tmux session/
Sleep 2s
Type "y"
Sleep 3s
Ctrl+U
Sleep 1s
Type "gc"
Sleep 1s
Enter
Sleep 4s

# 3. The session's shell window: state of every session, then where each
# one stands.
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
Sleep 7s

# 4. Cleanup: the squash-merged branch goes, busy sessions stay.
Hide
Type "clear"
Enter
Sleep 500ms
Show
Type "wts gc --apply"
Sleep 500ms
Enter
Wait+Line@60s /❯$/
Sleep 7s
