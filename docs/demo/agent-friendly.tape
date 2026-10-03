# wts from the agent's side: a detached creation and its JSON, an agent waited
# for, read and answered, and what the hooks tell an agent. Recorded by
# docs/demo/agent-friendly.zsh, which builds the sandbox — no agent, no model.

Output agent-friendly.raw.gif
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
Type "zsh -f docs/demo/agent-friendly.zsh --setup"
Enter
Sleep 12s
Show

# 1. An agent delegates: the session is created detached, its JSON on stdout.
Type "wts 'add a --json flag to wts brief' --json | jq -c '{name, branch, started}'"
Enter
Sleep 4s

# 2. Wait for another agent to stop working (it goes idle off-camera), then
#    read what it concluded and answer it.
Hide
Type "go-idle &!"
Enter
Type "clear"
Enter
Show
Type "wts wait rate-limit --timeout 60"
Enter
Sleep 7s
Type "wts tail rate-limit"
Enter
Sleep 4s
Type "wts send rate-limit 'yes, open the PR'"
Enter
Sleep 3s

# 3. What the hooks tell an agent. auth-form edits a file rate-limit edited:
#    the tool result says so, once.
Type "clear; cd ../api-worktrees/auth-form"
Enter
Sleep 1s
Type `print '{"tool_input":{"file_path":"src/limits.ts"}}' | wts-hook touch | jq -r .hookSpecificOutput.additionalContext`
Enter
Sleep 5s

# 4. rate-limit leaves a note; auth-form gets it at the start of its next turn.
Type "wts db set api-contract '429 now carries Retry-After' --session rate-limit"
Enter
Sleep 1500ms
Type "print '{}' | wts-hook prompt"
Enter
Sleep 4s

# 5. After /clear, the SessionStart context: its task and how it was linked,
#    the siblings, the file both have edited, and the skill for the rest.
Type "clear; wts-context | cut -c1-140"
Enter
Sleep 9s
