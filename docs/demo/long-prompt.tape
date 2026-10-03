# A 1.4 KB phrase, typed into the pane (1.6.0's layout) and then read from
# .wts/prompt (the built-in layout now). Recorded by docs/demo/long-prompt.zsh,
# which builds the sandbox this tape attaches to — no agent, no model call.

Output long-prompt.raw.gif
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
Type "zsh -f docs/demo/long-prompt.zsh --setup"
Enter
Sleep 4s
Show

# The phrase: 30 steps pasted from a ticket.
Type "wc -c < /tmp/wts-longprompt/spec.txt"
Enter
Sleep 2s

# 1. As 1.6.0 typed it: the line is cut at 1024 bytes, claude never starts.
Type 'wts before "$(</tmp/wts-longprompt/spec.txt)" typed'
Enter
Sleep 7s

# 2. Read from .wts/prompt: claude gets every byte.
Ctrl+B
Sleep 300ms
Type "L"
Sleep 800ms
Type "clear"
Enter
Type 'wts after "$(</tmp/wts-longprompt/spec.txt)"'
Enter
Sleep 7s
