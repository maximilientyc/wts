# Claude Code's status line as a source: setup claude --statusline (refused
# over your own, then installed), the line it prints in and out of a session,
# and the gauges in wts status --json, wts ls --wide and the switcher.
# Recorded by docs/demo/statusline-gauges.zsh, which builds the sandbox — no
# agent, no model. `payload` prints what Claude Code hands its status line.

Output statusline-gauges.raw.gif
Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 14
Set Width 1400
Set Height 860
Set Padding 20
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 40ms

Hide
Type "zsh -f docs/demo/statusline-gauges.zsh --setup"
Enter
Sleep 12s
Show

# 1. A status line of your own: left alone, and the one that runs both.
Type "wts setup claude --statusline"
Enter
Sleep 6s
Hide
Type "clear; jq 'del(.statusLine)' $CLAUDE_CONFIG_DIR/settings.json > ../s.json && mv ../s.json $CLAUDE_CONFIG_DIR/settings.json; clear"
Enter
Sleep 1s
Show
Type "wts setup claude --statusline && wts doctor | grep 'status line'"
Enter
Sleep 6s

# 2. The payload Claude Code hands it, and the line it prints in cors.
Type "clear; payload 84 2.10 cors | jq ."
Enter
Sleep 4s
Type "payload 84 2.10 cors | wts-hook statusline"
Enter
Sleep 4s

# 3. rate-limit waits on a permission, and left a note cors was not handed yet.
Type "as-claude rate-limit blocked; (cd $W/rate-limit && wts db set retry-after '429 carries Retry-After')"
Enter
Sleep 3s
Type "payload 84 2.10 cors | wts-hook statusline"
Enter
Sleep 5s

# 4. Outside a wts session: the model and the context, nothing written.
Type "(cd /tmp && payload 12 | wts-hook statusline)"
Enter
Sleep 4s

# 5. What it recorded, for scripts and for wts ls --wide.
Type "clear; wts status --json | jq -c '.[] | {name, context_pct, rate_limits, cost_reported_usd}'"
Enter
Sleep 5s
Type "wts ls --wide"
Enter
Sleep 6s

# 6. The switcher: [ctx 84%] on cors's row, ctx in each preview's first line.
Ctrl+B
Sleep 400ms
Type "s"
Wait+Screen@20s /session>/
Sleep 4s
Down
Sleep 4s
Up
Sleep 4s
Escape
Sleep 1500ms
