# wts db browse: the tables, the rows of archive with a record in the preview,
# esc back to the tables, enter printing a record. Recorded by
# docs/demo/db-browse.zsh, which builds the sandbox this tape attaches to — no
# agent, no model call.

Output db-browse.raw.gif
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
Type "zsh -f docs/demo/db-browse.zsh --setup"
Enter
Sleep 8s
Show

# 1. The tables with their counts; the schema of the one under the cursor.
Type "wts db browse"
Enter
Wait+Screen@15s /enter: rows of the table/
Sleep 2500ms
Down
Sleep 2s

# 2. The rows of archive, newest first; the record under the cursor on the right.
Type "archive"
Sleep 1s
Enter
Wait+Screen@15s /esc: back/
Sleep 3500ms
Down
Sleep 2500ms
Down
Sleep 2500ms

# 3. esc goes back to the tables.
Escape
Wait+Screen@15s /enter: rows of the table/
Sleep 2500ms

# 4. sessions: enter on a row prints that record and quits.
Type "sessions"
Sleep 1s
Enter
Wait+Screen@15s /esc: back/
Sleep 2500ms
Enter
Sleep 4s
