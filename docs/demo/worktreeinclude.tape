# .worktreeinclude: an ignored .env and a local config reach a new worktree,
# secret.env does not. Recorded by docs/demo/worktreeinclude.zsh, which builds
# the sandbox this tape attaches to — no agent, no model call.

Output worktreeinclude.raw.gif
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
Type "zsh -f docs/demo/worktreeinclude.zsh --setup"
Enter
Sleep 4s
Show

# The main checkout: what git ignores, and what the new worktree should get.
Type "git status --short --ignored"
Enter
Sleep 2s
Type "cat .worktreeinclude"
Enter
Sleep 2.5s

# A new session: the matching files are copied, one line says how many.
Type "wts env-setup"
Enter
Sleep 5s

# The worktree: .env and config/ are there, secret.env is not, still untracked.
Type "cd ../api-worktrees/env-setup && ls -a . config"
Enter
Sleep 3s
Type "git status --short --ignored"
Enter
Sleep 4s
