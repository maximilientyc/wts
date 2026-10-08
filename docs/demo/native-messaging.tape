# Two real agents reach each other with Claude Code's own messages. Recorded by
# docs/demo/native-messaging.zsh, which starts them (api-docs idle and waiting,
# rate-limit idle) on a tmux server of its own, prefix C-b.

Output native-messaging.raw.gif
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
Type "unset TMUX; TMUX_TMPDIR=/private/tmp/wts-nmdemo/tmux tmux attach -t '=demo'"
Enter
Sleep 2s
Type "clear"
Enter
Sleep 1s
Show

# 1. Messages between sessions work on this machine.
Type "wts doctor | grep messages"
Enter
Sleep 4s
Type "wts ls"
Enter
Sleep 4s

# 2. What rate-limit's agent was told at its start: the name to reach api-docs by.
Type "clear; (cd ../repo-worktrees/rate-limit && wts-context | grep -A2 'Sessions on')"
Enter
Sleep 6s

# 3. You ask rate-limit to ask api-docs. Watch rate-limit: SendMessage, then the
#    answer arrives as a message.
Type "wts send rate-limit 'Ask api-docs which endpoint it documents first, with SendMessage, then tell me its answer in one line.'"
Enter
Sleep 2s
Type "tmux switch-client -t '=rate-limit'"
Enter
Wait+Screen@150s /Message from @api-docs/
Sleep 12s

# 4. api-docs was idle: the message started a turn, and it answered the same way.
Ctrl+B
Type "L"
Sleep 1s
Type "clear; tmux switch-client -t '=api-docs'"
Enter
Sleep 7s
Ctrl+B
Type "L"
Sleep 1s

# 5. The hook recorded both as prompts of kind message, from their sender.
Type `clear; wts db sql "select session, kind, substr(message, 1, 60) from agent_events where event = 'prompt'"`
Enter
Sleep 7s
