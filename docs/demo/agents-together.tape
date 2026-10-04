# What one agent can do to another, once wts looks first: `wts ls --wide` with
# since when and the question, a prompt refused to a blocked agent and its
# answer sent, a wait that ends on an agent that quit, a send refused to the
# shell its pane has become, a session no agent ran in, and another session's
# notes refused without a terminal. Recorded by docs/demo/agents-together.zsh,
# which builds the sandbox — no agent, no model.

Output agents-together.raw.gif
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
Type "zsh -f docs/demo/agents-together.zsh --setup"
Enter
Sleep 14s
Show

# 1. Who is in what state, since when, and what the blocked one is asking.
Type "wts ls --wide"
Enter
Sleep 7s

# 2. A prompt sent to an agent that is asking a question would be typed into
#    the question: refused, with the question. --answer answers it.
Type "wts send cors 'also cover the OPTIONS preflight'"
Enter
Sleep 7s
Type "wts send cors --answer 1"
Enter
Sleep 4s

# 3. rate-limit's agent quit, its tmux session is still there: the wait
#    returns at once (it used to time out, every time), and a send is refused,
#    because that pane is now a shell.
Type "clear; wts wait rate-limit --timeout 30"
Enter
Sleep 4s
Type "wts send rate-limit 'open the PR'"
Enter
Sleep 7s

# 4. No agent ever ran in csv-export: the wait says so, not "call it again".
Type "wts wait csv-export --timeout 4"
Enter
Sleep 9s

# 5. An agent's Bash tool has no terminal: it leaves its own notes, not
#    another session's.
Type "clear; cd ../api-worktrees/auth-form"
Enter
Sleep 1s
Type "wts db set api-contract '429 with Retry-After' --session rate-limit </dev/null"
Enter
Sleep 6s
Type "wts db set api-contract '429 with Retry-After' </dev/null"
Enter
Sleep 4s
