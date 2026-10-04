# What one agent shares reaches its sibling exactly once: a note rewritten in
# the same second, a note written mid-turn, the first editor of a file, and a
# session that finished. Recorded by docs/demo/exact-delivery.zsh, which builds
# the sandbox and the note/turn/edit helpers — no agent, no model.

Output exact-delivery.raw.gif
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
Type "zsh -f docs/demo/exact-delivery.zsh --setup"
Enter
Sleep 12s
Show

# 1. A note rewritten in the second it was written: the reader's next turn
#    gets the second value (the clock comparison lost it).
Type "note rate-limit api '429 on /login'; note rate-limit api '429 + Retry-After'"
Enter
Sleep 2s
Type "turn auth-form"
Enter
Sleep 5s
Type "turn auth-form"
Enter
Sleep 4s

# 2. Mid-turn: the next edit carries a new note, the one after says nothing.
Type "clear; note rate-limit header 'X-RateLimit-Remaining'"
Enter
Sleep 2s
Type "edit auth-form src/form.ts"
Enter
Sleep 5s
Type "edit auth-form src/form.ts"
Enter
Sleep 4s

# 3. auth-form edits limits.ts first, rate-limit second: the second editor is
#    told at its edit, and the first at its next turn, once.
Type "clear; edit auth-form src/limits.ts"
Enter
Sleep 3s
Type "edit rate-limit src/limits.ts"
Enter
Sleep 6s
Type "turn auth-form"
Enter
Sleep 6s
Type "turn auth-form"
Enter
Sleep 4s

# 4. rate-limit is removed: its notes go with it, and auth-form hears that it
#    finished, how, and what it had said.
Type "clear; wts rm rate-limit -f"
Enter
Sleep 5s
Type "turn auth-form"
Enter
Sleep 7s
Type "turn auth-form"
Enter
Sleep 4s
