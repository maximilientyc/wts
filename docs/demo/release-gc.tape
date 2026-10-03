# wts gc picking up a branch squash-merged before a release rewrote its lines:
# the content test conflicts, the merged pull request still says it. Recorded
# by docs/demo/release-gc.zsh, which builds the sandbox this tape runs in — no
# agent, no model call, a stand-in gh.

Output release-gc.raw.gif
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
Type "zsh -f docs/demo/release-gc.zsh --setup"
Enter
Sleep 12s
Show

# 1. fix-login was squash-merged as #39, then 1.9.0 was released: the release
#    rewrote the very CHANGELOG line the squash had added.
Type "clear; git fetch -q && git --no-pager log --oneline -3 origin/main && git --no-pager diff origin/main~1 origin/main"
Enter
Sleep 6s

# 2. Without gh (--no-fetch), the content test conflicts: nothing to tear down.
Type "clear; wts gc --no-fetch"
Enter
Sleep 6s

# 3. With its fetch, gc asks gh once which PRs merged: #39, at fix-login's tip.
Type "clear; wts gc"
Enter
Sleep 7s

# 4. What gh said is now in pr_state: torn down and archived as squashed.
Type "clear; wts gc --apply --no-fetch"
Enter
Sleep 6s
Type "clear; wts log --no-things | jq -c '.work[] | {title, outcome: .sessions[0].outcome}'"
Enter
Sleep 5s
