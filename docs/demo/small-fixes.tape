# The visible half of the Linux CI PR's fixes: a name tmux would rewrite, an
# agent state outside the contract, a session named 1 in the preview, and the
# task screen's branch hint. Recorded by docs/demo/small-fixes.zsh, which
# builds the sandbox this tape attaches to — no agent, no model call.

Output small-fixes.raw.gif
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
Type "zsh -f docs/demo/small-fixes.zsh --setup"
Enter
Sleep 10s
Show

# 1. tmux would make `v1.2` a session `v1_2`, which wts then never found again.
Type "wts v1.2"
Enter
Sleep 3s

# 2. A state `claude agents` reports and wts does not know: none, not passed on.
Type "clear; wts status --json | jq -c '.[] | {name, agent_state}'"
Enter
Sleep 3500ms
Type "wts doctor 2>&1 | grep 'does not know'"
Enter
Sleep 4s

# 3. The switcher: the row of the session named 1 previews that session.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 2s
Type "1 "
Sleep 3500ms
Ctrl+U
Sleep 300ms

# 4. enter on a task, a branch: the hint says what the default layout does.
Type "migra"
Sleep 1200ms
Enter
Wait+Screen@10s /new session from a prompt/
Sleep 1500ms
Type "branch"
Sleep 800ms
Enter
Sleep 3500ms
Escape
Sleep 800ms
Escape
Sleep 800ms
Escape
Sleep 1500ms
