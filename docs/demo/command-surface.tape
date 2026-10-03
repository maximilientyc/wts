# The command surface: a typo refused, --help per command, wts doctor before
# and after the installs, Ctrl-C while naming, gc scoped to what wts made.
# Recorded by docs/demo/command-surface.zsh, which builds the sandbox this tape
# attaches to — no agent, no model call.

Output command-surface.raw.gif
Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 14
Set Width 1400
Set Height 860
Set Padding 20
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 45ms

Hide
Type "zsh -f docs/demo/command-surface.zsh --setup"
Enter
Sleep 12s
Show

# 1. A typo is refused, nothing created; every command answers --help.
Type "wts lsit"
Enter
Sleep 2500ms
Type "wts rm --help"
Enter
Sleep 3500ms

# 2. wts doctor, then the two installs, then doctor again.
Type "clear; wts doctor"
Enter
Sleep 6s
Type "clear; wts setup tmux --install; wts setup claude --install"
Enter
Sleep 3500ms
Type "clear; wts doctor | tail -11"
Enter
Sleep 5s

# 3. Ctrl-C while the model names the session: the name comes from the phrase.
Type "clear; WTS_NO_ATTACH=1 wts 'archive the old invoices'"
Enter
Sleep 3s
Ctrl+C
Sleep 3500ms

# 4. gc: only what wts made, and what --apply will cost.
Type "clear; wts gc --no-fetch"
Enter
Sleep 8s
