# Layouts

A layout says what a session opens: which windows, which panes, what runs in
them. The built-in `default` layout opens `$EDITOR` next to Claude Code, plus a
shell window. This guide is about writing your own.

```
wts <name> [layout] [context...]
wts layouts
```

## Where layouts are found

A layout is a [tmuxinator](https://github.com/tmuxinator/tmuxinator) project
file (ERB + YAML). `wts <name> <layout>` looks it up in this order:

1. `$WTS_LAYOUTS_PATH/<layout>.yml`, by default
   `${XDG_CONFIG_HOME:-~/.config}/wts/layouts/`
2. the built-in `<prefix>/share/wts/layouts/<layout>.yml`

A user layout shadows a built-in one of the same name. `wts layouts` lists what
is found, with paths.

To start your own from the default one:

```sh
mkdir -p ~/.config/wts/layouts
cp "$(wts layouts | awk -F'\t' '$1 == "default" { print $2 }')" ~/.config/wts/layouts/feature.yml
```

[`examples/layouts/`](../examples/layouts) has two richer ones: `feature`
(nvim, Claude, dev servers, lazygit) and `sentry` (Claude starts investigating
the issue id given as context).

tmuxinator is started with `--project-config <file> --name <session>`, so your
own `~/.config/tmuxinator` projects are untouched.

## Branch prefix

A layout declares the prefix of the branches it creates in a comment line,
conventionally the first one. Without it, the branch is the session name.

```yaml
# wts: branch_prefix=feature/
```

`WTS_BRANCH_PREFIX` overrides it for one call, even when empty:
`WTS_BRANCH_PREFIX= wts login-flow feature`.

## Variables exposed to layouts

Readable in ERB with `ENV['…']`:

| Variable          | Value |
|-------------------|-------|
| `WTS_NAME`        | session name (given, or proposed from the phrase) |
| `WTS_ROOT`        | absolute path of the worktree |
| `WTS_WORKDIR`     | `WTS_ROOT` + `WTS_SUBDIR` when set, else `WTS_ROOT` |
| `WTS_CONTEXT`     | remaining arguments, joined |
| `WTS_PROMPT`      | the phrase of `wts "<phrase>"` (empty otherwise) |
| `WTS_PROMPT_FILE` | absolute path of a file holding that phrase (`.wts/prompt` in the worktree), empty without one |
| `WTS_DOC`         | the path of the [context file](documents.md#where-it-lands), relative to the pane's working directory |
| `WTS_RESTORE`     | `1` during `wts restore` |
| `WTS_RESUME`      | `1` during `wts restore` when a Claude conversation exists |
| `WTS_RESUME_ID`   | during `wts restore`, the id of the agent's own conversation when the hooks recorded it and its transcript exists |

- Use `WTS_WORKDIR` for `root:` and `WTS_ROOT` for commands that must run from
  the worktree root.
- Panes do not inherit the environment of `wts` (the tmux server is already
  running): read variables in ERB, not in pane commands.

## Starting Claude with the phrase

Copy the `claude_cmd` block of the built-in `default.yml`, which escapes the
phrase for the pane's shell and picks up `WTS_DOC`.

Have the pane read the phrase from `WTS_PROMPT_FILE` (`claude "$(cat <file>)"`)
rather than type it: tmuxinator types the pane's command before its shell is
ready, and the terminal then keeps 1024 bytes of a line, so a long phrase typed
whole loses its end and Claude never starts.

The built-in and example layouts start Claude with `--name <WTS_NAME>`, so the
conversation carries the session's name in `/resume` and Claude Code's own
agent list instead of its first prompt. Only on creation: on restore the
pre-filled `claude --resume` keeps the name the conversation already has. The
name is checked like `WTS_DOC` (letters, digits, `.`, `_`, `/`, `-`, not a
leading `-`) before it is interpolated into the pane's command line; any other
name starts Claude without `--name`.

## The Claude pane on restore

On `wts restore` the command is pre-filled rather than run
([sessions.md](sessions.md#the-claude-pane-on-restore)). This is the restore
branch of `default.yml`'s `claude_cmd`:

```erb
<% claude_cmd =
    if restore
      if ENV['WTS_RESUME_ID'].to_s =~ /\A[0-9a-f-]+\z/
        %Q{" print -z 'claude --resume #{ENV['WTS_RESUME_ID']}'"}
      elsif ENV['WTS_RESUME'].to_s == '1'
        %q{" print -z 'claude --continue'"}
      elsif doc.empty?
        %q{" print -z claude"}
      else
        %Q{" print -z 'claude \\"Read @#{doc} first: it is the context for this session.\\"'"}
      end
    else
      inner
    end %>
        - <%= claude_cmd %>
```

`inner` is the command of a normal start, built from `WTS_PROMPT_FILE` and
`WTS_DOC`; `default.yml` shows how.

## Keep layouts ASCII

Keep layout files **ASCII**, comments included: without a UTF-8 locale
(`LANG=C`), Ruby refuses to read them ("invalid byte sequence in US-ASCII").
