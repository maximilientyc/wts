# What wts reads back of what it writes: a session's brief and notes above its
# pane, a task's previous attempts, the REPO column and gc --all. Recorded by
# docs/demo/read-data.zsh, which builds the sandbox this tape attaches to — no
# agent, no model call.

Output read-data.raw.gif
Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 14
Set Width 1400
Set Height 800
Set Padding 20
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 45ms

Hide
Type "zsh -f docs/demo/read-data.zsh --setup"
Enter
Sleep 10s
Show

# 1. The switcher on a session: its brief and its agent's notes above the pane.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 1s
Type "auth"
Sleep 4500ms

# 2. A task tried once already: the previous attempt, retrospective and all.
Ctrl+U
Sleep 300ms
Type "rate"
Sleep 6s
Escape
Sleep 1s

# 3. Two repositories: wts ls names them, gc --all collects both from anywhere.
Type "clear; wts ls"
Enter
Sleep 3500ms
Type "clear; cd /tmp && wts gc --all --no-fetch"
Enter
Sleep 6s
