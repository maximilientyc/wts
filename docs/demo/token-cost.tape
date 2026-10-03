# Tokens and cost per session and per task: wts ls --wide before and after the
# brief that counts them, the task's total over its attempts, and wts log.
# Recorded by docs/demo/token-cost.zsh, which builds the sandbox this tape
# attaches to — no agent, no model call.

Output token-cost.raw.gif
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
Type "zsh -f docs/demo/token-cost.zsh --setup"
Enter
Sleep 10s
Show

# 1. Nothing counted yet: ls never reads a transcript.
Type "clear; wts ls --wide"
Enter
Sleep 3500ms

# 2. wts brief counts them (no model here: WTS_NO_LLM=1), then the columns fill.
Type "clear; wts brief >/dev/null 2>&1; wts ls --wide"
Enter
Sleep 5s

# 3. What the task cost, over both attempts.
Type "clear; wts task show $(wts task ls --json | jq -r '.tasks[0].id') | tail -5"
Enter
Sleep 4500ms

# 4. The same numbers in the journal, per work item.
Type "clear; wts log --brief | jq -c '.work[] | {title, usage: (.usage | {tokens, cost_usd, sessions})}'"
Enter
Sleep 6s
