# ctrl-t creating a task in the switcher, and enter on a task asking what to do
# with it: a new session from a branch name, or attaching the task to a session
# that already exists. Recorded by docs/demo/new-task.zsh, which builds the
# sandbox this tape attaches to — no agent, no model call.

Output new-task.raw.gif
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
Type "zsh -f docs/demo/new-task.zsh --setup"
Enter
Sleep 8s
Show

# 1. The switcher, and ctrl-t: a task typed without leaving it.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 2500ms
Ctrl+T
Sleep 1500ms
Type "Write the migration guide"
Sleep 800ms
Enter
# The row appears under the sessions, the cursor on it, its preview on the right.
Sleep 3500ms

# 2. tab on it: a note, kept on the task for whichever session takes it.
Tab
Sleep 1s
Type "keep the v1 endpoints until March"
Sleep 600ms
Enter
Sleep 2s
Escape
Sleep 1500ms

# 3. enter on the task: what to do with it.
Type "migra"
Sleep 1200ms
Enter
Wait+Screen@10s /new session from a prompt/
Sleep 3500ms
Type "branch"
Sleep 1s
Enter
Sleep 2s
# The name is pre-filled from the title; `feature/` typed by habit is dropped.
Ctrl+U
Sleep 400ms
Type "feature/migration-guide"
Sleep 1s
Enter
# wts-fresh: fetch, worktree, session, and the client switches to it.
Wait+Screen@30s /migration-guide ❯/
Sleep 3s

# 4. Back in the switcher: the task now rides on its session (the * in SUBJECT).
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 3500ms

# 5. Work that already has a session: attach the task to it instead.
Ctrl+T
Sleep 1s
Type "Rate-limit the public API"
Sleep 600ms
Enter
Sleep 3s
Enter
Wait+Screen@10s /new session from a prompt/
Sleep 1500ms
Type "auth"
Sleep 1500ms
Enter
Sleep 2s
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 4s
Escape
Sleep 1s
