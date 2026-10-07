# What the seventh hook and the payload fields change: an agent run again in
# its pane reads idle and takes a prompt, a compaction leaves a working agent
# working, `wts tail` reads the transcript Claude Code named, an overlap found
# at a subagent's edit says so, and the built-in layout names the conversation.
# Recorded by docs/demo/claude-hooks.zsh, which builds the sandbox — no agent,
# no model. `as-claude` runs the hooks with Claude Code's payloads.

Output claude-hooks.raw.gif
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
Type "zsh -f docs/demo/claude-hooks.zsh --setup"
Enter
Sleep 12s
Show

# 1. Seven hooks, one of them new.
Type "wts doctor | grep 'Claude hooks'"
Enter
Sleep 4s

# 2. rate-limit's agent quit: stopped. claude is run again in its pane: the
#    SessionStart hook records a start, and the agent reads idle at once. A
#    send goes through, where it used to need --force until a first prompt.
Type "wts ls"
Enter
Sleep 4s
Type "as-claude rate-limit start startup; wts ls"
Enter
Sleep 5s
Type "wts send rate-limit 'open the PR'"
Enter
Sleep 4s

# 3. A compaction is a start too, of kind compact: cors stays working.
Type "clear; as-claude cors start compact; wts ls"
Enter
Sleep 4s
Type `wts db sql "select session, event, kind from agent_events where event = 'start'"`
Enter
Sleep 5s

# 4. The transcript Claude Code named, outside the worktree's project folder.
Type "clear; wts db sql 'select session, transcript from agent_panes'"
Enter
Sleep 4s
Type "wts tail rate-limit"
Enter
Sleep 5s

# 5. A subagent of cors edits a file rate-limit has edited: the news says so.
Type "clear; as-claude cors edit src/limits.ts subagent"
Enter
Sleep 6s

# 6. The built-in layout starts claude with the session's name.
Type "clear; wts layouts"
Enter
Sleep 3s
Type `WTS_NAME=csv-export WTS_PROMPT='export users' tmuxinator debug --suppress-tmux-version-warning --project-config $(wts layouts | awk -F'\t' '$1 == "default" {print $2}') | grep -o 'claude.*'`
Enter
Sleep 7s
