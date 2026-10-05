# WTS_RETRO_MODEL: the retrospectives' own model, named by gc's dry run and
# used by --apply. Recorded by docs/demo/retro-model.zsh, which builds the
# sandbox this tape runs in — no agent, no model call, a stand-in claude.

Output retro-model.raw.gif
Set Shell zsh
Set FontFamily "Hack Nerd Font Mono"
Set FontSize 14
Set Width 1400
Set Height 600
Set Padding 20
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 45ms

Hide
Type "zsh -f docs/demo/retro-model.zsh --setup"
Enter
Sleep 10s
Show

# 1. Neither variable set: the retrospectives fall back to haiku.
Type "clear; wts gc --no-fetch"
Enter
Sleep 5s

# 2. A model of their own; naming and wts brief keep WTS_MODEL.
Type "clear; export WTS_RETRO_MODEL=opus; wts gc --no-fetch"
Enter
Sleep 5s

# 3. --apply asks that model, and the archive keeps which one it was.
Type "clear; wts gc --no-fetch --apply"
Enter
Sleep 6s
Type "clear; wts log --no-things | jq '.work[0].sessions[0].retro'"
Enter
Sleep 5s
