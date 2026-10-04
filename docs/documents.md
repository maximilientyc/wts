# Context documents: `wts doc`

A technical spec in Notion, an architecture page, a file of conventions on
disk: the same context, pasted by hand into every new agent. `wts doc` keeps a
small library of those documents, fetched once and cached, and `--doc` attaches
one to a session: the agent opens on it.

```
wts doc add <url|path> | ls [--json] | show [--json] | sync | forget
wts doc use <slug> [session] | tools
```

## Attaching a document

```sh
wts doc add https://www.notion.so/Payments-architecture-abc123   # once, ~10-30 s
wts auth-form "limit the rate per key" --doc payments-architecture
wts auth-form "limit the rate per key" --doc    # pick one from the library
wts fix-typo "a comma too many"                 # nothing attached
```

**Nothing is attached unless you ask for it.** There is deliberately no
per-repository pinning: several projects run at once, and the document that
matters to one worktree is noise in the next.

`--doc` is repeatable and takes a slug of `wts doc ls`, a URL, or a path.

- It **always consumes the next argument**; a bare `--doc` at the very end of
  the line opens an fzf picker instead.
- `wts <name> <layout> --doc <slug>` is the unambiguous order, and
  `--doc=<slug>` works anywhere.

A task can carry documents too, handed to every session on it:
[tasks.md](tasks.md).

## The commands

```
wts doc add <url|path> [--name <slug>] [--force]   add a document
wts doc ls                                         the library
wts doc show <slug>                                what will be injected
wts doc sync [<slug>...] [--force]                 fetch again
wts doc forget <slug>                              remove it from the library
wts doc use <slug> [<session>]                     attach to a running session
wts doc tools [--refresh]                          what the fetch may use
```

`wts doc ls --json` and `wts doc show <slug> --json` answer for scripts and
agents ([agents.md](agents.md#driving-wts-from-an-agent)).

## Attaching to a session already running

```sh
wts doc use payments-architecture             # from inside the worktree
wts doc use payments-architecture auth-form   # or by name, typo-tolerant
```

The context file is rewritten and the reference is sent into the agent's pane,
so an agent already working picks it up without being restarted. In the
switcher, `ctrl-e` does the same on the highlighted row, picker included.

## Where it lands

wts writes `<worktree>/.wts/context.md`: every attached document one after
another, each with its title, source and fetch date. The Claude pane starts on
`claude "Read @.wts/context.md first, …"`.

The `.wts` folder carries its own `.gitignore` containing `*`, so it never
appears in `git status`, never makes a worktree look dirty to `wts gc`, and goes
away with the worktree.

Layouts receive the path in `WTS_DOC`, relative to the pane's working directory
(Claude Code resolves an `@` reference from the pane's cwd). A layout of your
own picks it up with the few lines the built-in `default.yml` uses
([layouts.md](layouts.md)).

## Freshness

- `wts doc add` fetches.
- On attach, a URL older than `WTS_DOC_TTL` (24 h) is fetched again, under a
  timeout, falling back to the cache when the network or the connector is
  missing: an attach is never blocked by them.
- `wts doc sync` refreshes on demand.
- A fetch that comes back a fraction of the cached size is refused and the
  cache kept (`--force` accepts it): silently replacing a good spec with a stub
  is the worst thing this could do.
- A local markdown file never calls the model at all, and is re-read on every
  attach.

**When nothing can read it, the document degrades to a pointer:** the context
file carries the URL and asks the agent to fetch it itself. The agent in the
pane has your full set of connectors and often succeeds where the headless call
could not. The same happens offline, without `claude`, or with `WTS_NO_LLM=1`.

## Where the library is

The library is `~/.config/wts/docs.json` (`WTS_DOCS_PATH`), four keys per entry,
meant to be edited by hand. The fetched content is a cache, in the state
database (table `doc_cache`).

The variables that tune fetching (`WTS_DOC_TTL`, `WTS_DOC_TIMEOUT`,
`WTS_DOC_MODEL`, `WTS_DOC_TOOLS`, `WTS_DOC_TOOLS_TTL`, `WTS_DOC_MAX_BYTES`)
are in [configuration.md](configuration.md#documents).

## Privacy and fidelity

- `wts doc add` and `wts doc sync` send the document's URL to the model through
  your own `claude -p`, which then reads the page with your own connectors. Set
  `WTS_NO_LLM=1` to never call the model: documents then stay pointers. See
  [What is sent to the model](../README.md#what-is-sent-to-the-model).
- **The content is written in clear text inside the worktree**
  (`.wts/context.md`). Keep secrets out of the library.
- **A document fetched through `WebFetch` is a model's rendering of the page,
  not the page.** That tool summarizes whatever it reads, and asking it not to
  does not change that. A document read through an MCP connector comes back
  verbatim; check with `wts doc show <slug>` when fidelity matters.

## How it works: whatever this machine can read

A URL is fetched by a headless `claude -p` started with **this machine's own MCP
configuration**, and the model uses whatever tool can read it. Nothing about a
particular provider is hardcoded, on purpose: the same page sits behind a Notion
connector on one machine and behind a gateway with entirely different tool names
on another, and both work with no configuration.

The allow list is built per server from `claude mcp list`, plus `WebFetch`, with
every write-shaped tool denied. The enumeration is cached for a day: the CLI
refuses a bare `mcp__*` wildcard in an allow rule, so the servers have to be
named. `WTS_DOC_TOOLS='mcp__<server>__*'` pins the list when that enumeration
is noisy or when only one connector should ever be used. `wts doc tools` shows
what the fetch may use.
