# The switcher at fourteen sessions over two repositories: the counts per
# state on its first line, the REPO column, ctrl-g down to the sessions that
# need you and back. Recorded by docs/demo/switcher-filter.zsh, which builds
# the sandbox this tape attaches to — no agent, no model call.

Output switcher-filter.raw.gif
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
Type "zsh -f docs/demo/switcher-filter.zsh --setup"
Enter
Sleep 20s
Show

# 1. Every row: fourteen sessions, two tasks, the counts above the titles.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 4500ms

# 2. ctrl-g: only what needs you, the prompt and the first line say so.
Ctrl+G
Wait+Screen@10s /needs you>/
Sleep 3s
Down
Sleep 1500ms
Down
Sleep 1500ms
Down
Sleep 2500ms

# 3. ctrl-g again: every row back, same columns.
Ctrl+G
Wait+Screen@10s /session>/
Sleep 3500ms
Escape
Sleep 1s
