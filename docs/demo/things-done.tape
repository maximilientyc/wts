# A task completed in Things leaves the switcher at the next `wts task ls`.
# From 1.6.0 to 1.8.3 it stayed: the read of Things was refused in silence for
# a person at a terminal. Recorded by docs/demo/things-done.zsh, which builds
# the sandbox this tape attaches to — no agent, no model call, and a Things
# database of the sandbox's own.

Output things-done.raw.gif
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
Type "zsh -f docs/demo/things-done.zsh --setup"
Enter
Sleep 8s
Show

# 1. The switcher: "Rotate API keys" is still listed, open, although
# it was completed in Things an hour ago.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 4s
Escape
Sleep 1500ms

# 2. wts task ls reads Things again, at a terminal: the task is completed.
Type "wts task ls --all"
Sleep 700ms
Enter
Wait+Screen@20s /completed/
Sleep 4s

# 3. The switcher again: the completed task is gone, the open ones stay.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 4500ms
Escape
Sleep 1s
