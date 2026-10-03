# PR, CI and review state per session: wts pr --refresh, the switcher's PR
# column with merged last, the preview, and ctrl-d on a squash-merged session.
# Recorded by docs/demo/pr-state.zsh, which builds the sandbox this tape
# attaches to — no agent, no model call, a stand-in gh.

Output pr-state.raw.gif
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
Type "zsh -f docs/demo/pr-state.zsh --setup"
Enter
Sleep 12s
Show

# 1. One gh call per session, in parallel, cached.
Type "clear; wts pr --refresh"
Enter
Sleep 4s

# 2. The switcher: a PR column, the merged session last.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 3s
Type "rate"
Sleep 3500ms

# 3. Merged by squash: the preview says so, and ctrl-d takes it, no -f needed.
Ctrl+U
Sleep 300ms
Type "fix"
Sleep 3500ms
Ctrl+D
Sleep 2s
Type "y"
Sleep 4s
Ctrl+U
Sleep 3s
Escape
Sleep 1s

# 4. The same cache, for scripts and agents.
Type "clear; wts status --json | jq -c '.[] | {name, merged, pr: .pr.number, checks: .pr.checks}'"
Enter
Sleep 5s
