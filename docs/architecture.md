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
--- worklog #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

A timestamped entry starts an interval that ends at the next timestamped entry;
the final entry only closes the interval before it. Metadata belongs to the
interval that starts at the entry.

```text
08:00-10:00  planning          #ClientA   @office
10:00-13:00  implementation    #ClientA   @home
13:00-14:00  internal meeting  #internal  @home
14:00-17:00  client followup   #ClientA   @client
```

`#tag` and `@location` are sticky: if an entry omits one, it inherits the current
value. `#-` clears the active tag and `@-` the active location. `#ooo` marks
out-of-office time — it contributes to `activity` but not `workday`.

## Reporting model

All reporting starts from intervals. Each interval has:

```text
duration
activity text
tag
location
workday_excluded
```

These dimensions each partition the interval set, so:

```text
sum(item totals) = sum(tag totals) = sum(location totals) = activity total
workday total    = sum(intervals where workday_excluded = false)
```

## Module overview

```text
document.lua      -> syntax-preserving parser
analyze.lua       -> semantic analyzer
diagnostics.lua   -> shared diagnostic messages
journal.lua       -> pure journal date/path helpers
entry.lua         -> single-entry parser/formatter
body.lua          -> body reconstruction
summary.lua       -> reporting domain (intervals, sections, sorting, logged totals)
projection.lua    -> generic row grouping/projection engine
quantize.lua      -> largest-remainder rounding arithmetic
summary_block.lua -> locate a worklog's single generated summary region
render.lua        -> output rendering
usecases/         -> pure command operations (incl. insert_entry)
sources/          -> external work-item sources (pure providers + shell IO/UI)
init.lua          -> Neovim shell
```

## Summary model

A worklog has at most one summary. The summary is a **pure projection** of the
worklog's entries: it stores no authored content and is always safe to rebuild
from source. It is created with the worklog (`:WorklogToday` and `:WorklogCopy`
append one) and kept current by the refresh below; `:WorklogLog` marks the
contributing source entries `!L` and rebuilds it. Annotations belong on entries
(canonical, surviving copy/order), not in the summary.

Keeping authored content out of the summary is what makes regeneration safe. The
`refresh_summaries` usecase exploits this: it ensures *every* valid worklog has a
current summary — updating a stale one, creating a missing one, never removing one —
not just the active one, skipping invalid worklogs and emitting no edit where a
summary is already current. Alongside the edits it
returns `warnings` (each `{ row, message }`) for every problem the analyzer can
see — a broken or absent header, out-of-order timestamps, an invalid entry —
whether or not the worklog has a summary, and even for a structurally broken
document (which produces no edits).

`:WorklogRefresh` and the optional `auto_summary` autocmds in `init.lua` are thin
shells over it — the trigger (`off` / `change` / `idle` / `save`) is configurable,
and the shell adds only undo-join, a re-entrancy guard, and cursor preservation.
The warnings are published as buffer diagnostics (a `vim.diagnostic` namespace),
which is what makes them clear when fixed however the fix happened: each refresh
replaces the namespace's diagnostics, so a now-valid worklog publishes an empty
set. Because programmatic edits do not fire the change autocmds, the
buffer-editing commands republish diagnostics after applying (so `:WorklogOrder`
clears its own warning). Diagnostics also render inline in any mode, so there is
no insert-mode timing to manage. The reporting core (`summary.lua`, `render.lua`)
stays pure so the journal reports (`:WorklogWeek` / `:WorklogDays`) share it
unchanged; an open report re-derives on the same `auto_summary` autocmds,
rebuilding from a spec stored on its buffer so it tracks its source days the way
an in-file summary tracks its entries. Each day section in a report labels its
header with that day's own `q=` bucket (`week.lua` carries `quantize_minutes`
per day; the aggregate header stays bare).

## Parsing and semantics

`document.lua` parses source lines into syntax nodes, preserving raw text, row
numbers, line kinds, metadata tokens, header option tokens, and invalid time-like
lines. It recognizes `#tag`, `#-`, `@location`, `@-`, `key=value`, `HH:MM`, and
`--- worklog ... ---`, but assigns no business meaning — it parses `#ooo` as a
tag, and `analyze.lua` decides it is excluded from workday.

`analyze.lua` turns syntax into meaning: worklog block discovery, sticky
tag/location state, clear-token semantics, `#ooo` exclusion, block-local
`quantize` and `duration` interpretation, and diagnostics. A semantic entry
carries both explicit and effective metadata:

```lua
{
  row = 2,
  minutes = 480,
  text = "planning",
  explicit_tag = nil, explicit_tag_clear = nil, tag = "ClientA",
  explicit_location = nil, explicit_location_clear = nil, location = "office",
  workday_excluded = false,
}
```

Quantization and duration formatting are block-local; consumers read
`block.quantize_minutes` and `block.duration_format`.

## Entry and body

`entry.lua` parses and formats one timestamped entry, relative to the current
sticky state, emitting only the metadata needed to preserve meaning. If the
current tag is `ClientA`, returning to untagged work renders as `10:00 resume #-`.

`body.lua` rebuilds worklog block bodies: normalized and sorted body lines,
insertion indexes, sticky state before insertion, and canonical emission of `#-`
and `@-`. Because clear tokens exist, a reordering rewrite can preserve meaning
explicitly:

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

## Reporting: summaries and quantization

`summary.lua` builds intervals from adjacent semantic entries (`entry[i] ->
entry[i + 1]`); the final entry closes the previous interval and produces none of
its own. There is one summary type, always quantized to the worklog's
`q=<minutes>` bucket (default 15); `q=1` reproduces exact, unrounded
durations. Durations render as decimal hours or `hh:mm`, each with its `(+Nm)`
rounding error (`(+0m)` when exact). The summary header echoes the worklog's
`q=`/`d=` as a read-only banner (`--- summary q=<n> d=<fmt> ---`) built by
`syntax.summary_header` and regenerated on refresh, so the worklog header stays the
single source of truth.

Quantization rounds full-grain rows. The full grain is `activity text + tag +
location + workday_excluded`; intervals sharing a grain are summed before
rounding. With bucket size `q` (default 15) and exact activity total `A`, the
target rounded total is:

```text
Q = floor((A + q / 2) / q) * q
```

For each full-grain row `r`, start at `base(r) = floor(exact(r) / q) * q` with
`remainder(r) = exact(r) - base(r)`. Let `B = sum base(r)` and `k = (Q - B) / q`;
give one extra bucket to the `k` rows with the largest remainders, breaking ties
by first-seen order. The per-row rounding error is `exact(r) - quantized(r)`.

Quantized rows project into displayed sections:

```text
main summary rows -> activity text + tag + workday_excluded
tag totals        -> tag
location totals   -> location
overall totals    -> all rows
```

Rows with `workday_excluded = true` contribute to activity totals but not workday
totals.

## Summary ordering and rendering

Main summary rows group by `activity text + tag + workday_excluded`; location is
reported only in location totals. Main rows never render location, render `#tag`
only when the same activity text appears under multiple tags, and keep
same-text/different-tag rows adjacent.

Ordering:

1. group main rows by activity text
2. sort text groups by displayed duration descending
3. sort tag variants inside each text group by displayed duration descending
4. tie-break by exact duration, then first-seen order

Tag and location totals sort by displayed duration, then exact duration, then
first-seen order.

`render.lua` turns semantic output objects into lines and owns presentation only:
omit placeholder-only tag/location sections, omit `activity` when it equals
`workday`, render missing tags as `(untagged)` and missing locations as
`(no location)`, and hide main-summary tags unless needed for disambiguation. It
does not decide reporting semantics or ordering.

## Usecases, edit scripts, and the shell

A usecase is a pure command operation: it accepts plain Lua input, calls
context/analyze/body/summary helpers, and returns an edit script or an error
message — never the Neovim API.

```lua
local result, err = append_summary.run(lines)
-- success: { edits = { { start_index = 4, end_index = 4, lines = { ... } } } }
-- failure: nil, "worklog: ..."
```

An edit script is the project's core data structure:

```lua
{ start_index = 1, end_index = 3, lines = { "08:00 plan", "09:00 done" } }
```

`init.lua` applies it with `nvim_buf_set_lines(0, start_index, end_index, false,
lines)`. Indexes are zero-based to match the Neovim buffer API.

`init.lua` is the Neovim shell: it registers filetype support and user commands,
reads buffer lines, cursor row, and current time, expands configured journal
paths before calling pure journal helpers, calls usecases, applies edit scripts,
and shows warnings. It contains no worklog semantics.

The shell is a thin *layer*, not a single file. Alongside `init.lua`, the only
code that touches Neovim, IO, or UI is `health.lua` (the `:checkhealth` probe) and
the sources shell modules (`sources/http`, `sources/sync`, `sources/telescope`).
The semantic core -- and even the source providers -- stay pure; see below.

## Sources

External work-item sources (e.g. Azure DevOps) let `:WorklogInsert <source>` pick a
tracker item and insert it, while keeping the same pure-core discipline: the
provider logic is pure and only IO/UI is shell.

A source is a plain table implementing a small contract:

```text
fetch(cb)            -- async: cb(items|nil, err); the default item set
format_item(item)    -- item -> picker display line
to_entry_text(item)  -- item -> inserted activity text
search(query, cb)    -- optional: async live search (cb(items|nil, err))
```

An item is `{ id, title, type?, state?, url? }` (`id`/`title` required). Built-in
source types are declared in `setup{ sources = { ... } }`; custom sources register
directly via `require("worklog.sources.registry").register(name, source)`, which
validates the contract.

Layering:

```text
sources/registry.lua      pure   contract, name registry, register/validate
sources/cache.lua         pure   cache envelope codec + TTL staleness
sources/azure_devops.lua  pure   the ADO provider (pure via injected deps)
sources/http.lua          shell  the only networked file: curl via jobstart
sources/sync.lua          shell  on-disk cache + lazy-TTL / :WorklogSync refresh
sources/telescope.lua     shell  optional live type-as-you-search picker
```

The ADO provider stays pure through **dependency injection**: `init.lua` hands it
`{ transport, json, token_resolver }`, so all HTTP/JSON/secret access goes through
injected deps and the provider is unit-tested offline with a fake transport.

Pick-time is offline and synchronous: read the per-source JSON cache
(`stdpath('cache')/worklog/sources/<name>.json`) and open the picker. The cache is
refreshed only by the occasional sync (in the background when stale, or via
`:WorklogSync`), never in the hot path. The PAT is resolved lazily by
`token_resolver` and never written to the cache.

Insertion still flows through the pure `usecases/insert_entry` + an edit script, and
`insert_entry` runs the text through `entry.sanitize_text` so a work-item title can
never inject trailing `#tag` / `@location` / `!L` metadata -- no source has to
remember to do it.

Telescope is optional. `:WorklogInsert <source>` uses `vim.ui.select` (which any
ui-select provider upgrades) by default; when Telescope is installed and the source
implements `search`, it opens the live picker that searches the whole tracker as you
type. Live whole-project search is the only Telescope-exclusive capability --
everything else is picker-agnostic.

## Error philosophy

Prefer explicit syntax over silent semantic corruption. A rewrite emits `#-` / `@-`
when it returns to untagged or unlocated work, and keeps `#ooo` out of workday
while counting it in activity — rather than silently turning untagged work into
`#ClientA`, no-location work into `@office`, or folding `#ooo` into workday.

## Testing expectations

Core areas under test: syntax parsing; sticky tag/location inheritance; `#-` and
`@-`; `#ooo`; summaries and quantization (including `q=1` exactness); tag
and location totals; copy, order, repeat, and insert behavior; equal-timestamp
insertion; and quantized summary invariants.

Tooling and the local gate (`just install`, `just check`, `just --list`, and the
raw headless test/health commands) are documented in the README and `justfile`.

## Future ideas

- Tree-sitter syntax highlighting
- export formats
- richer reports
- validation command
- more filetype niceties
