# worklog.nvim architecture

`worklog.nvim` is a Neovim plugin for structured plain-text worklogs.

The core pipeline is:

```text
source lines -> syntax nodes -> semantic worklog -> edit scripts
```

Design goals:

- keep worklogs human-readable
- preserve the worklog as the source of truth
- derive reproducible summaries
- keep Neovim API usage out of the semantic core
- prefer explicit syntax over silent semantic changes

## Core model

A worklog is a sequence of timestamped entries inside a worklog block.

```text
--- worklog #ClientA @office quantize=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

A timestamped entry starts an interval. The interval ends at the next timestamped
entry.

Metadata belongs to the interval that starts at the entry.

```text
08:00-10:00  planning          #ClientA   @office
10:00-13:00  implementation    #ClientA   @home
13:00-14:00  internal meeting  #internal  @home
14:00-17:00  client followup   #ClientA   @client
```

`#tag` and `@location` are sticky. If an entry omits one, it inherits the current
value.

```text
#-   clears the active tag
@-   clears the active location
```

`#ooo` marks out-of-office time. It contributes to `activity`, but not
`workday`.

## Reporting model

All reporting starts from intervals.

Each interval has:

```text
duration
activity text
tag
location
workday_excluded
```

The dimensions partition the interval set:

```text
activity text      partitions intervals by what was done
tag                partitions intervals by reporting bucket
location           partitions intervals by where the work happened
workday_excluded   partitions intervals into workday and non-workday time
```

Therefore:

```text
sum(item totals)     = activity total
sum(tag totals)      = activity total
sum(location totals) = activity total
```

And:

```text
workday total = sum(intervals where workday_excluded = false)
```

## Module overview

```text
document.lua   -> syntax-preserving parser
analyze.lua    -> semantic analyzer
entry.lua      -> single-entry parser/formatter
body.lua       -> body reconstruction
summary.lua    -> reporting and quantization
render.lua     -> output rendering
usecases/      -> pure command operations
init.lua       -> Neovim shell
```

## `document.lua`

`document.lua` parses source lines into syntax nodes.

It preserves:

- raw line text
- row numbers
- line kinds
- metadata tokens
- header option tokens
- invalid time-like entry lines

It recognizes syntax such as:

```text
#tag
#-
@location
@-
key=value
HH:MM
--- worklog ... ---
```

It does not assign business meaning. For example, it parses `#ooo` as a tag;
`analyze.lua` decides that `#ooo` is excluded from workday.

## `analyze.lua`

`analyze.lua` turns syntax into meaning.

It owns:

- worklog block discovery
- sticky tag and location state
- clear-token semantics
- `#ooo` exclusion
- block-local `quantize` interpretation
- diagnostics

A semantic entry has explicit metadata and effective metadata:

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

  workday_excluded = false,
}
```

Quantization is block-local. Consumers should use:

```lua
block.quantize_minutes
```

## `entry.lua`

`entry.lua` parses and formats one timestamped entry.

Formatting is relative to the current sticky state. It emits only the metadata
needed to preserve meaning.

If the current tag is `ClientA`, returning to untagged work renders as:

```text
10:00 resume #-
```

## `body.lua`

`body.lua` rebuilds worklog block bodies.

It owns:

- normalized body lines
- sorted body lines
- insertion indexes
- sticky state before insertion
- canonical emission of `#-` and `@-`

Because clear tokens exist, body rewrites can preserve meaning explicitly.

```text
--- worklog ---
09:00 done
08:00 plan #sales @client
```

can become:

```text
--- worklog ---
08:00 plan #sales @client
09:00 done #- @-
```

## `summary.lua`

`summary.lua` owns reporting.

It builds intervals from adjacent semantic entries:

```text
entry[i] -> entry[i + 1]
```

The final timestamped entry closes the previous interval and does not produce its
own interval.

Exact summaries use raw interval durations.

## Quantization

Quantization rounds full-grain rows.

The full grain is:

```text
activity text + tag + location + workday_excluded
```

Intervals with the same full grain are summed before rounding.

Let `q` be the bucket size in minutes. If omitted:

```text
q = 15
```

Let `A` be the exact activity total.

The target rounded activity total is:

```text
Q = floor((A + q / 2) / q) * q
```

For each full-grain row `r`:

```text
base(r)      = floor(exact(r) / q) * q
remainder(r) = exact(r) - base(r)
```

Set:

```text
quantized(r) = base(r)
```

Let:

```text
B = sum base(r)
k = (Q - B) / q
```

Give one additional bucket to the `k` rows with the largest remainders. Break
ties by first-seen row order.

For each row:

```text
error(r) = exact(r) - quantized(r)
```

The quantized full-grain rows are projected into displayed sections:

```text
main summary rows -> activity text + tag + workday_excluded
tag totals        -> tag
location totals   -> location
overall totals    -> all rows
```

Rows where `workday_excluded = true` contribute to activity totals, but not workday
totals.

## Summary ordering and rendering

Main summary rows group by:

```text
activity text + tag + workday_excluded
```

Location is reported only in location totals.

Main summary rows:

- never render location
- render `#tag` only when the same activity text appears under multiple tags
- keep same-text different-tag rows adjacent

Ordering:

1. group main rows by activity text
2. sort text groups by displayed duration descending
3. sort tag variants inside each text group by displayed duration descending
4. use exact duration and first-seen order as tie-breakers

Tag and location totals are sorted by displayed duration, then exact duration,
then first-seen order.

## `render.lua`

`render.lua` turns semantic output objects into lines.

It may handle presentation rules:

- omit placeholder-only tag/location sections
- omit `activity` when it equals `workday`
- render missing tags as `(untagged)`
- render missing locations as `(no location)`
- hide main-summary tags unless needed for disambiguation

It should not decide reporting semantics or ordering.

## `usecases/`

Usecase modules are pure command operations.

A usecase should:

- accept plain Lua inputs
- call context/analyze/body/summary helpers
- return an edit script or an error message
- avoid direct Neovim API calls

Example:

```lua
local result, err = append_summary.run(lines)
```

Success:

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

Failure:

```lua
nil, "worklog: ..."
```

## Edit scripts

An edit script is a project data structure.

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

`init.lua` applies edits with:

```lua
vim.api.nvim_buf_set_lines(0, start_index, end_index, false, lines)
```

Indexes are zero-based because the Neovim buffer API is zero-based.

## `init.lua`

`init.lua` is the Neovim shell.

It should:

- register filetype support
- register user commands
- read buffer lines
- read cursor row and current time where needed
- call usecases
- apply edit scripts
- show warnings

It should not contain worklog semantics.

## Error philosophy

Prefer explicit syntax over silent semantic corruption.

Good behavior:

```text
emit #- when a rewrite returns to untagged work
emit @- when a rewrite returns to no location
exclude #ooo from workday while keeping it in activity
```

Bad behavior:

```text
change untagged work into #ClientA
change no-location work into @office
include #ooo in workday
```

## Testing expectations

Core areas:

- syntax parsing
- sticky tag/location inheritance
- `#-` and `@-`
- `#ooo`
- exact summaries
- quantized summaries
- tag totals
- location totals
- copy, order, repeat, and insert behavior
- equal timestamp insertion behavior
- quantized summary invariants

Set up local contributor tooling once:

```sh
just install
```

This configures `git` to use the repository's `.githooks/` directory.

Local verification is split between `just static-check` and `just nvim-check`.
Run `just check` for the full local gate.

For available convenience recipes, run `just --list` or inspect `justfile`.

```sh
just --list
```

Run the full test suite directly:

```sh
nvim --headless -i NONE -u NONE \
  "+set rtp+=." \
  "+lua dofile('tests/run.lua')" \
  +qa!
```

Run the Neovim health check directly:

```sh
nvim --headless -u NONE \
  "+set rtp+=." \
  "+checkhealth worklog" \
  +qa
```

## Future ideas

Possible improvements:

- Tree-sitter syntax highlighting
- export formats
- richer reports
- validation command
- more filetype niceties
