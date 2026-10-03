# wts gc picking up a branch squash-merged from three commits, and leaving one
# that got a commit after its squash. Recorded by docs/demo/squash-gc.zsh, which
# builds the sandbox this tape runs in — no agent, no model call.

Output squash-gc.raw.gif
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
Type "zsh -f docs/demo/squash-gc.zsh --setup"
Enter
Sleep 12s
Show

# 1. Three sessions; fix-login (3 commits) and rate-limit (4) were squash-merged
#    on GitHub, and rate-limit's agent committed once more after.
Type "wts ls"
Enter
Sleep 3s

# 2. gc fetches, then compares: fix-login is in the teardown, rate-limit is not.
Type "clear; wts gc"
Enter
Sleep 7s

# 3. What GitHub did: one commit per pull request.
Type "clear; git --no-pager log --oneline -4 origin/main && wts status --json | jq -c '.[] | {name, merged}'"
Enter
Sleep 5s

# 4. Torn down and archived as squashed.
Type "clear; wts gc --apply --no-fetch"
Enter
Sleep 6s
Type "clear; wts log --no-things | jq -c '.work[] | {title, status, outcome: .sessions[0].outcome}'"
Enter
Sleep 5s
