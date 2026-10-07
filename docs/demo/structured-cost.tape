# wts brief asks for a JSON answer against a schema, and the cost of that call
# shows in the session's usage, under wts:brief. Recorded by
# docs/demo/structured-cost.zsh, which builds the sandbox this tape runs in —
# no agent, no model call.

Output structured-cost.raw.gif
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
Type "zsh -f docs/demo/structured-cost.zsh --setup"
Enter
Sleep 8s
Show

# 1. The summary: two fields of a JSON answer.
Type "wts brief rate-limit"
Enter
Sleep 5s

# 2. What it cost, as claude reported it, under wts:brief.
Type "wts status --json rate-limit | jq '.[0].usage | {cost_usd, model, models}'"
Enter
Sleep 5s
Type "wts db sql 'SELECT transcript, model, messages, output, cost_usd FROM usage'"
Enter
Sleep 6s
