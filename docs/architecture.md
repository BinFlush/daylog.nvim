# worklog.nvim architecture

`worklog.nvim` is a structured plain-text worklog plugin for Neovim.

The codebase is organized around a semantic core: source lines are parsed into
syntax nodes, analyzed into worklog meaning, and used by pure command use cases
that return edit scripts.

The main design goals are:

- keep the worklog file human-readable
- preserve the worklog as a source of truth
- support structured reporting without requiring a database
- make derived summaries reproducible
- keep Neovim integration separate from worklog semantics

## Core model

A worklog is a small domain language.

Example:

```text
--- worklog #ClientA @office quantize=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

This means:

```text
08:00-10:00  planning          #ClientA   @office
10:00-13:00  implementation    #ClientA   @home
13:00-14:00  internal meeting  #internal  @home
14:00-17:00  client followup   #ClientA   @client
```

`#tag` and `@location` are sticky. Clear tokens make sticky-to-empty transitions
explicit:

```text
#- clears the active tag
@- clears the active location
```

## Module overview

```text
document.lua   -> syntax-preserving parser
analyze.lua    -> semantic analyzer
entry.lua      -> single-entry parser/formatter
body.lua       -> body reconstruction
summary.lua    -> reporting
render.lua     -> output rendering
usecases/      -> pure command operations
init.lua       -> Neovim shell
```

## `document.lua`

`document.lua` parses source lines into syntax nodes.

It should preserve:

- raw line text
- source rows
- line kinds
- syntactic metadata tokens

It may recognize syntax shapes such as:

```text
#tag
#-
@location
@-
key=value
HH:MM
--- worklog ... ---
--- summary exact ---
```

But it should not decide their semantic meaning.

For example, it may know that `#ooo` is a tag token, but it should not decide
that `#ooo` is excluded from workday. That belongs in `analyze.lua`.

## `analyze.lua`

`analyze.lua` turns syntax into meaning.

It owns:

- worklog block discovery
- effective sticky tag/location per entry
- tag/location clear semantics
- `#ooo` exclusion
- block-local `quantize` interpretation
- semantic diagnostics
- unordered timestamp diagnostics

A semantic entry should contain both explicit and effective metadata where
needed:

```lua
{
  row = 2,
  minutes = 480,
  text = "planning",
  explicit_tag = nil,
  explicit_tag_clear = nil,
  tag = "ClientA",
  explicit_location = nil,
  explicit_location_clear = nil,
  location = "office",
  excluded = false,
}
```

The analyzer is the source of truth for command-time behavior.

## Sticky metadata

Rules:

- The header may initialize tag and location for that block.
- An entry may set tag, location, or both.
- An entry may clear tag with `#-`.
- An entry may clear location with `@-`.
- Omitted metadata inherits the current sticky value.
- `#ooo` is a normal sticky tag with special reporting meaning.
- `#ooo` intervals count toward `activity`, but not `workday`.

Clear-only headers such as this are harmless and canonicalize to no header
metadata:

```text
--- worklog #- @- ---
```

## `entry.lua`

`entry.lua` handles one timestamped entry.

It parses a single line into semantic entry data and formats an entry back to a
canonical source line.

It is used by commands such as insert, repeat, copy, and order.

## `body.lua`

`body.lua` rebuilds worklog block bodies.

It owns:

- normalized body lines
- sorted body lines
- insertion index
- sticky state before an insertion point
- canonical emission of `#-` and `@-` when needed

Body rewrites are intentionally infallible now that `#-` and `@-` exist. Any
transition from sticky metadata back to nil can be represented explicitly.

For example, a rewrite can safely emit:

```text
08:00 client work #ClientA @client
10:00 untagged local work #- @-
```

rather than silently changing the meaning of the second entry.

## `summary.lua`

`summary.lua` owns reporting.

It builds intervals from semantic entries:

```text
entry[i] -> entry[i + 1]
```

Then it groups and totals by semantic meaning.

It reports:

- item totals
- tag totals
- location totals
- activity total
- workday total

Exact summaries use raw durations.

Quantized summaries round grouped time into the block’s configured bucket size.

Ordering belongs in `summary.lua`, not `render.lua`.

Summary lists should already be sorted before rendering:

```text
duration descending
exact duration descending as tie-breaker when relevant
stable original order as final tie-breaker
```

## `render.lua`

`render.lua` turns summary objects and worklog line lists into output lines.

It should not decide semantics. It should mostly print the data it receives.

It may omit redundant sections, such as placeholder-only tag/location summaries
or `activity` when it is identical to `workday`.

## `usecases/`

The `usecases/` directory contains pure command modules.

A usecase should:

- accept plain Lua inputs
- call context/analyze/body/summary helpers
- return either an edit script or an error message
- avoid direct Neovim API calls

Example:

```lua
local result, err = append_summary.run(lines)
```

On success:

```lua
{
  edits = {
    {
      start_index = 4,
      end_index = 4,
      lines = { ... },
    },
  },
}
```

On failure:

```lua
nil, "worklog: ..."
```

This keeps command behavior easy to test without Neovim UI state.

## Edit scripts

An edit script is a project-level data structure, not a Neovim concept.

It describes how to change the buffer.

Example:

```lua
{
  start_index = 1,
  end_index = 3,
  lines = {
    "08:00 plan",
    "09:00 done",
  },
}
```

`init.lua` applies this with:

```lua
vim.api.nvim_buf_set_lines(0, start_index, end_index, false, lines)
```

These indexes are zero-based because the Neovim buffer API is zero-based.

## `init.lua`

`init.lua` is the Neovim shell.

It should:

- register filetype support
- register user commands
- gather buffer lines
- gather cursor row/current time where needed
- call usecases
- apply edit scripts
- show warnings

It should not contain worklog business logic.

## Command flow

`:WorklogSummarize`:

```text
init.lua
  gets current buffer lines
  calls usecases.append_summary.run(lines)

append_summary.lua
  resolves active worklog context
  validates target block
  calls summary.summarize_block(block)
  calls render.summary_lines(...)
  returns append edit

init.lua
  applies returned edit script
```

`:WorklogRepeat`:

```text
init.lua
  gets lines, cursor row, current time
  calls usecases.repeat_current.run(lines, row, time)

repeat_current.lua
  resolves worklog under cursor
  finds semantic item at row
  computes insertion point
  computes sticky state at insertion point
  formats a repeated entry that preserves meaning
  emits #-/@- when needed
  returns insert edit

init.lua
  applies returned edit script
```

## Error philosophy

Prefer explicit syntax over silent semantic corruption.

Good behavior:

```text
emit #- when a rewrite needs to return to untagged work
emit @- when a rewrite needs to return to no location
exclude #ooo from workday while keeping it in activity
```

Bad behavior:

```text
silently changing untagged work into #ClientA
silently changing no-location work into @office
silently including #ooo in workday
```

## Future ideas

Possible future improvements:

- Tree-sitter syntax highlighting
- export formats for external reporting systems
- richer reports
- validation command
- health check
- more filetype niceties

Avoid adding features before the core workflow has been used in real worklogs.

## Testing expectations

Core areas that need tests:

- syntax parsing
- header metadata
- sticky tag inheritance
- sticky location inheritance
- `#-`
- `@-`
- `#ooo`
- exact summaries
- quantized summaries
- tag totals
- location totals
- copy behavior
- order behavior
- repeat behavior
- equal timestamp insertion behavior

Run:

```sh
nvim --headless -i NONE -u NONE \
  "+set rtp+=." \
  "+lua dofile('tests/run.lua')" \
  +qa!
```

Smoke check:

```sh
nvim --headless -u NONE \
  "+set rtp+=." \
  "+lua require('worklog').setup()" \
  +qa
```

## Design principle

Keep the plugin focused, plain-text, and reliable.

The worklog file is the user’s source of truth. Derived blocks are useful, but
they must not distort the meaning of the source data.
