# daylog.nvim architecture

`daylog.nvim` is a Neovim plugin for structured plain-text logs.

The core pipeline is:

```text
source lines -> syntax nodes -> semantic log -> edit scripts
```

Design goals:

- keep logs human-readable
- preserve the log as the source of truth
- derive reproducible summaries
- keep Neovim API usage out of the semantic core
- prefer explicit syntax over silent semantic changes

## Core model

A log is a sequence of timestamped entries inside a log block.

```text
--- log #ClientA @office q=30 ---
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
value. `#-` clears the active tag and `@-` the active location.

A **blank entry** — a bare `HH:MM` timestamp with no activity text — marks uncounted
time. Its interval is excluded from every report ("not calculated in any shape or
form"):

```text
08:00 planning
11:00
13:00 client followup
```

Here `11:00–13:00` is uncounted; only the two real activities count. A blank carries
no reporting metadata — no tag, location, logging marker, `=> alias`, or `round±N`
nudge — and any that slip in raise the `blank_entry_metadata` diagnostic. A `utc`
offset is allowed (it records a clock change during the gap, not a report attribute).
Notes may still follow a blank. A blank is neither a map nor a rename target.

## Reporting model

All reporting starts from intervals. Blank entries start no interval, so uncounted
time never reaches the report. Each interval has:

```text
duration
activity text
tag
location
```

These dimensions each partition the interval set, so:

```text
sum(item totals) = sum(tag totals) = sum(location totals) = activity total
```

The totals section is a single `workday` row — the whole counted day, which equals
the activity total — so it foots to the same total as tags and locations.

The "activity text" an interval reports under is its **resolved label**: an entry's
mapping alias (`=> label`) when it has one, else its own description. A bare entry and a
mapped one are therefore interchangeable in the report — `08:00 1 Item one` and
`08:00 fix login => 1 Item one` both report under "1 Item one". **Mapping is optional and
additive**: a user may never map (logging source items, or anything, as bare rows), map
some entries, or fold heterogeneous descriptions onto one label — the report treats all
three the same. No command may assume an activity row is "really" a mapping or "really" a
bare description; both are first-class. (This is why renaming an entry may target a source
item, and why renaming an activity _row_ — a group that may mix both — is refused; rename
edits one entry's text, `:Daylog map` relabels the report.)

## Logging

An entry can be marked **logged** — reported to an external system — at any of four independent levels:
`!S[]` (its summary row / activity), `!T[]` (its tag), `!L[]` (its location), `!W[]` (the workday). A
frozen marker `!X[]<minutes>` commits that cell to a value; a valueless `!X[]` only flags it. The
brackets are mandatory — a plain `!X` with no brackets is activity text, not a marker. Markers write as
one compact token in `S T L W` order (`!S[]225T[]525W[]525`); the separated form (`!S[]225 !T[]525`)
parses too.
`:Daylog log` on a rendered row writes the marker on that cell's
entries (a summary `!S[]` per (activity, location) slice, so a location-spanning activity's slices SUM);
the markers live on the entries, so the summary stays a pure projection.

Logging is **rounding that reports**. Every report section is a re-sum of ONE shared granule
quantization, and a committed cell splits that honest total for display:

```text
reported slice  = the committed value V
remaining slice = cell_total − V   (the honest remainder, which absorbs V's over/under-shoot)
```

so the cell — and every partition — still foots to its honest total (**absorb**). When `V` exceeds the
cell's tracked time there is no remainder to absorb into, so the surplus inflates the cell's granules and
propagates to every partition that contains them (**propagate**). The one honest limit: two
over-commitments at cross-cutting levels (a tag and a location whose granule sets overlap without
nesting) can contradict — no integer rounding satisfies both. The quantizer detects this after applying
them, falls back to the honest quantization (so footing always holds), and `logging_diagnostics` warns
that the commitments contradict. Diagnostics also flag an off-grid frozen value and same-cell values
that disagree.

### Named logging

A marker may carry a **name-set** — `!T[jira,boss]` — recording who or what the slice was reported to.
Names use the tag charset and are a canonical, sorted set (parsed by `syntax.parse_name_list`). The
**unnamed name is the empty string `""`**, a first-class member that sorts first: `!S[]` is `{""}` and
`!S[,hey]` is `{"", "hey"}`, so `!S[]` is "logged to no one" — distinct from an unlogged
row, and addable alongside real names (a marker always carries at least `{""}`). The name-set at a level
is **part of that level's group identity**: a cell's granule carries all four level signatures (the
`!S[]`/`!T[]`/`!L[]`/`!W[]` name-sets it belongs to), so two differently-named slices of one cell report as separate
rows and split independently, while a same-named slice merges. Marking **adds** the chosen names (including
`""`) to the row's slice: `:Daylog log` unions them onto a currently-logged slice, or sweeps an unlogged
remainder *plus* the same-name logged slice and rewrites every swept entry at their combined displayed
total, so re-logging a grown cell folds the new time into the existing named commitment rather than forking
a rival row. A **fresh mark of an unlogged remainder starts from nothing** — its cell's display name-set is
not inherited (only a currently-logged slice contributes existing names to the union). Unmarking removes
the chosen names, clearing the marker once its last name is gone.

Names are chosen through `:Daylog log`'s picker, wired in the shell (`init.lua` → `pick.pick_names`). The
**corpus** of previously-used names is scanned from the trailing daybook files — the same buffer-aware
window the insert picker uses — by `rank.build_name_usage`, which credits each name one frecency visit
per level per day and buckets `{ s, t, l, w }` maps; `pick.name_corpus` frecency-ranks one level's names
(score desc, name asc) and the picker prepends a synthetic `(unnamed)` row. The picker itself stays pure
where it can: `sources/picker.name_corpus_rows` (ordering) and `parse_names_input` (the comma-input
grammar) are pure and tested; the Telescope multi-select and the `vim.fn.input` fallback are the thin
shell.

## Module overview

```text
syntax.lua        -> shared vocabulary: node/token/block kinds, diagnostic codes, codecs
document.lua      -> syntax-preserving parser
analyze.lua       -> semantic analyzer
context.lua       -> log block selection (active / at cursor row)
diagnostics.lua   -> shared diagnostic messages
config.lua        -> setup option validation and merge
daybook.lua       -> pure daybook date/path helpers
entry.lua         -> single-entry parser/formatter
body.lua          -> body reconstruction
summary.lua       -> reporting domain (intervals, sections, sorting, logged totals)
projection.lua    -> generic row grouping/projection engine
quantize.lua      -> largest-remainder rounding arithmetic
summary_block.lua -> locate a log's single generated summary region
render.lua        -> output rendering
export.lua        -> machine-readable CSV/JSON dump of the summary block (all levels + residuals) (pure)
commit_audit.lua  -> classify a git commit's .day changes (notes/today/other-day) + flag any warning (pure)
week.lua          -> daybook week/days report assembly (reuses the reporting core)
highlight.lua     -> parser-driven highlight spans (pure)
text.lua          -> small shared text predicates (e.g. is_empty)
usecases/         -> pure command operations (incl. insert_entry, support helpers)
sources/          -> external work-item sources (pure providers + shell IO/UI)

-- the shell layer: the only modules that touch the Neovim API / IO / UI
init.lua          -> shell: setup, autocmds, source wiring, edit-script application
commands.lua      -> shell: user-command and autocmd definitions
buffer.lua        -> shell: buffer/cursor/clock, edit application, diagnostic + highlight publishing
report.lua        -> shell: multi-day report buffers + export (preview buffer or file write)
rename.lua        -> shell: rename picker / confirm / multi-file write
map.lua           -> shell: mapping picker
pick.lua          -> shell: mixed-row picker (Telescope or vim.ui.select)
daybook_io.lua    -> shell: daybook file IO and buffer/path resolution
commit_audit_install.lua -> shell: write the daybook commit-audit post-commit hook
current_time.lua  -> shell: current-time stamping + cross-day carryover
filetype.lua      -> shell: filetype registration
telescope.lua     -> shell: optional Telescope live-search picker (insert + rename)
health.lua        -> shell: the :checkhealth probe
ftplugin/daylog.lua -> shell: attach the highlighter to daylog buffers
```

## Summary model

A log has at most one summary. The summary is a **pure projection** of the
log's entries: it stores no authored content and is always safe to rebuild
from source. It is created with the log (`:Daylog today` and `:Daylog copy`
append one) and kept current by the refresh below; `:Daylog log` marks the
contributing source entries `!L` and rebuilds it. Annotations belong on entries
(canonical, surviving copy/order), not in the summary.

Keeping authored content out of the summary is what makes regeneration safe. The
`refresh_summaries` usecase exploits this fully: the summary is an *entirely
generated, edit-free zone*, so a refresh **blasts the whole zone** — from the
body/summary boundary down to the next log / EOF — and rewrites it canonically
(the body, then exactly two blank separator lines, then the content-only summary
render). Anything found in that zone — mid-summary prose, a stranded summary row, a
jumble of duplicated/stale sections, trailing junk — is discarded; only the body
above the boundary and the entries are protected. It ensures *every* valid log has
a current summary — updating a stale one, creating a missing one, never removing one
— not just the active one, skipping invalid logs and emitting no edit where a
zone is already canonical. The whole problem reduces to finding the top boundary:
`summary_block` finds the summary banner (`--- summary q=N d=fmt ---`) in the tail —
an exact match first, else the nearest line by character-level edit distance to
reclaim a *mangled* banner, guarded to stay below the last entry and require real
similarity so a body note is never mistaken for it — and falls back to the surviving
generated shape (anchored on a summary section header) when a border edit deleted the
banner outright. This collapses a jumble of stale or duplicated generated sections
back into one summary. Alongside the edits it
returns `warnings` (each `{ row, message }`) for every problem the analyzer can
see — a broken or absent header, out-of-order timestamps, an invalid entry —
whether or not the log has a summary, and even for a structurally broken
document (which produces no edits).

**One writer owns the zone.** That blast is the single way a log's summary is written
into a buffer: `support.summary_zone_edit` finds the body boundary, renders the projection
over the (possibly modified) entries, and replaces `[boundary .. zone end)` with the
canonical *two blank lines + content* — a no-op when the zone is already canonical. Every
entry-changing command rebuilds its log's **existing** summary through it: the in-place
commands (`:Daylog balance`/`:Daylog split`/`:Daylog log`/`:Daylog map`/`:Daylog rename`) emit it
in their own edit, so the change is atomic, instant, and independent of `auto_summary`;
`:Daylog order` runs it per reordered log after re-analysing the sorted bodies; and
`refresh_summaries` uses it to rebuild every log and *create* the missing ones. The
field-changing commands (`:Daylog map`/`:Daylog balance`/`:Daylog log`) derive both halves of their
edit — the source-line rewrite and this summary rebuild — from one per-entry override map
(`support.apply_entry_overrides`), so the written line and the recomputed projection can never
disagree about a change. Because the
two-blank separator belongs to the **zone** — emitted by the writer, never authored, never
owned by the body — a command may restructure the body freely (`:Daylog order` re-sorts and
re-spaces it) and the separator is re-established canonically on the rebuild. The lone
exception is the *mid-entry* commands (`:Daylog insert`/`:Daylog repeat`): they insert an entry
and `startinsert`, so the entry is unfinished and they leave the rebuild to `auto_summary`.

`:Daylog refresh` and the optional `auto_summary` autocmds in `init.lua` are thin
shells over it — the trigger (`off` / `change` / `idle` / `save`) is configurable,
and the shell adds only undo-join, a re-entrancy guard, and cursor preservation.
The warnings are published as buffer diagnostics (a `vim.diagnostic` namespace),
which is what makes them clear when fixed however the fix happened: each refresh
replaces the namespace's diagnostics, so a now-valid log publishes an empty
set. Because programmatic edits do not fire the change autocmds, the
buffer-editing commands republish diagnostics after applying (so `:Daylog order`
clears its own warning). Diagnostics also render inline in any mode, so there is
no insert-mode timing to manage. The reporting core (`summary.lua`, `render.lua`)
stays pure so the daybook reports (`:Daylog report`) share it
unchanged; an open report re-derives on the same `auto_summary` autocmds,
rebuilding from a spec stored on its buffer so it tracks its source days the way
an in-file summary tracks its entries. Each day section in a report labels its
header with that day's own `q=` bucket (`week.lua` carries `quantize_minutes`
per day; the aggregate header stays bare).

The report is read-only but is now an actionable surface: `:Daylog rename` on it
renames an item across days. `render.*_report_layout` exposes the report as a flat
layout (one row per rendered line, tagged with its section scope), so
`usecases/report_cursor` maps the cursor to a target and the file scope (an
aggregate row spans the period, a per-day row one file). The rename then fans out
**by value** -- `rename_summary.run_by_value` re-finds the item in each day's own
recomputed summary and rewrites that file -- so no cross-file provenance has to be
threaded through `combine_summaries`; each day stays self-describing. The shell
writes each affected file (open buffer or disk) after a confirmation and rebuilds
the open reports.

## Parsing and semantics

`document.lua` parses source lines into syntax nodes, preserving raw text, row
numbers, line kinds, metadata tokens, header option tokens, and invalid time-like
lines. It recognizes `#tag`, `#-`, `@location`, `@-`, `key=value`, `HH:MM`, and
`--- log ... ---`, but assigns no business meaning — a bare `HH:MM` with no text is
just an entry node with empty text.

`analyze.lua` turns syntax into meaning: log block discovery, sticky
tag/location state, clear-token semantics, block-local `quantize` and `duration`
interpretation, and diagnostics — including `blank_entry_metadata`, which flags a
blank entry (empty text) that carries a tag, location, marker, alias, or round
nudge (a `utc` offset is allowed). A semantic entry carries both explicit and
effective metadata:

```lua
{
  row = 2,
  minutes = 480,
  text = "planning",
  explicit_tag = nil, explicit_tag_clear = nil, tag = "ClientA",
  explicit_location = nil, explicit_location_clear = nil, location = "office",
}
```

Quantization and duration formatting are block-local; consumers read
`block.quantize_minutes` and `block.duration_format`.

## Entry and body

`entry.lua` parses and formats one timestamped entry, relative to the current
sticky state, emitting only the metadata needed to preserve meaning. If the
current tag is `ClientA`, returning to untagged work renders as `10:00 resume #-`.

`body.lua` rebuilds log block bodies: normalized and sorted body lines,
insertion indexes, sticky state before insertion, and canonical emission of `#-`
and `@-`. Because clear tokens exist, a reordering rewrite can preserve meaning
explicitly:

```text
--- log ---
09:00 done
08:00 plan #sales @client
```

can become:

```text
--- log ---
08:00 plan #sales @client
09:00 done #- @-
```

## Reporting: summaries and quantization

`summary.lua` builds intervals from adjacent semantic entries (`entry[i] ->
entry[i + 1]`); the final entry closes the previous interval and produces none of
its own. A blank entry (empty text, `summary.is_blank_entry`) starts no interval,
so `build_intervals` skips it and its gap lands in no report. There is one summary
type, always quantized to the log's
`q=<minutes>` bucket (default 15); `q=1` reproduces exact, unrounded
durations. Durations render as decimal hours or `hh:mm`, each with its `(+Nm)`
rounding error (`(+0m)` when exact). The summary header echoes the log's
`q=`/`d=` as a read-only banner (`--- summary q=<n> d=<fmt> ---`) built by
`syntax.summary_header` and regenerated on refresh, so the log header stays the
single source of truth.

Quantization rounds granules. The granule is `(text, tag, location)`; intervals
sharing a granule are summed before rounding. With bucket size `q` (default 15)
and exact activity total `A`, the
target rounded total is:

```text
Q = floor((A + q / 2) / q) * q
```

For each granule `r`, start at `base(r) = floor(exact(r) / q) * q` with
`remainder(r) = exact(r) - base(r)`. Let `B = sum base(r)` and `k = (Q - B) / q`;
give one extra bucket to the `k` rows with the largest remainders, breaking ties
by first-seen order. The per-row rounding error is `exact(r) - quantized(r)`.

Logged commitments (`!S[]`/`!T[]`/`!L[]`/`!W[]<n>`) are handled per the **Logging** section above: the granule
quantization stays honest, and a committed cell splits its honest total into a reported slice (`V`) and a
remaining slice (`cell_total − V`) for display, so every section still foots. An over-commit beyond the
cell's tracked time inflates its granules and propagates; a cross-cutting contradiction falls back to the
honest quantization and is diagnosed (`quantize.constrained_quantize`, `summary.quantize_granules`).

Quantized granules project into displayed sections:

```text
main summary rows -> activity text + tag
tag totals        -> tag
location totals   -> location
overall totals    -> workday (the whole counted day)
```

### Manual rounding balance (`round±N`)

Largest-remainder rounding can leave an aggregate (a day, hence a week) a step or
two off a clean total. `:Daylog balance` lets the cursor on a summary row — or a
entry — shift the rounding by `±N` `q`-steps, recorded as a **non-sticky**
per-entry `round±N` marker (`usecases/balance_summary.lua`, `syntax.parse_round_nudge`).

The model is a single vector and a guarantee:

- The **granule** (`(text, tag, location)`) is the *only* thing quantized; every
  report section is a re-sum of the granules. A nudge is one integer per granule that overrides its
  bucket count (`quantize.quantize_rows` second pass: `Q = max(0, base + (blocks + nudge)*q)`); it
  changes only that granule's value, never the set or grouping. (A separate full-grain row that also
  carries the `logged` flag feeds `:Daylog balance` and `logging_diagnostics`, not the display.)
- A row's nudge is shared by all of its intervals, so the command marks **all** of
  them and they fold by signed max-magnitude (`projection.project_rows` `nudge_mode
  = "max"`); sections sum row nudges (`"sum"`) for the cumulative marker shown on
  every affected line.
- **Footing is structural.** Every displayed section is a partition of the granules, and
  `Σ groups = Σ cells` holds for *any* granule values — so no nudge configuration, and no feasible
  commitment, can break it (a committed cell's reported + remaining slices sum to its granule total; an
  infeasible cross-cutting set falls back to honest). The corollaries follow: every whole-cell level
  agrees on the activity total, the `workday` total equals it, and `displayed + residual = true`
  everywhere. The week aggregate (`combine_summaries`) is the same partition one level up — pure sums of
  days, no re-quantization — so a per-day nudge flows in unchanged.
- The calculator distributes a requested group shift to the least-error rows
  (largest-remainder-optimal). A nudge necessarily moves one group on *every* axis
  it touches (each cell has a tag, a location, a title…); that coupling is inherent
  to the projection and is fully visible via the markers.

`tests/balance_invariants.lua` encodes these guarantees as a property test:
adversarial per-cell nudge vectors over synthesized day and week summaries, with
every section's rows asserted to foot to its total in both duration formats.

## Summary ordering and rendering

Main summary rows group by `activity text + tag`; location is
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
omit placeholder-only tag/location sections, render the totals as a single
`workday` row, render missing tags as `(untagged)` and missing locations as
`(no location)`, and hide main-summary tags unless needed for disambiguation. It
does not decide reporting semantics or ordering.

## Highlighting

Highlighting is parser-driven, so there is one grammar, not two. `highlight.lua`
(pure) owns **no patterns of its own**: every recognition decision comes from the
parser layer, and this module only chooses which highlight group each parsed token
gets. It turns the parse into spans -- `{ line, col_start, col_end, group,
priority }`, 0-based byte columns matching the extmark API. Token positions and
shapes come from `document` (`document.tokens`, `document.classify_control_token`,
`document.quant_error_spans`, `document.summary_duration_length`,
`document.is_option_token` -- the only place these patterns live); header validity
and the rows inside a summary section come from `analyze`; the generated
section-header predicate is `syntax.is_summary_section_header` (shared with the
summary locator). Daylog headers, entries, and trailing metadata are classified
straight from the parse. Summary rows -- derived output, not source -- are
recognized by the shapes `render.lua` emits (a leading duration, `(+Nm)` markers,
trailing metadata); a summary section runs from a generated section header to the
blank line that ends it, and the same predicate matches the labeled multi-day
report headers (`--- day summary <date> q=N ---`), so the `:Daylog report`
reports highlight too. Whole-line "base" spans (a header, a note)
sit at a lower priority than the narrower token spans layered over them, so a
`#tag` inside a header wins at its own cells.

The shell applies the spans as extmarks in a dedicated namespace:
`ftplugin/daylog.lua` attaches the highlighter to any daylog buffer (so it works
without `setup()`) and refreshes it on change, the report buffers highlight
themselves on build/refresh, and the edit-applying path re-highlights after the
programmatic edits that do not fire change autocmds. `init.lua` registers the
highlight groups as default links, so a user's own `highlight` overrides win.

## Time bar

`:Daylog bar` turns the active log's intervals into a horizontal, time-proportional
strip: each interval is a coloured segment whose cell width is its share of the real
recorded duration (largest-remainder rounding so the widths sum to exactly the bar
width), coloured by resolved-label activity in first-appearance order — the same colour
map as the margin indicator and the summary. `timebar.lua` is pure; `timebar_ui.lua` is
the shell.

A blank entry's dead period is a single-cell `gap` marker, *not* time-proportional, so the
bar's x-axis is **piecewise linear**: each segment carries its own `[start, stop)` clock
span, and the now-marker and the hover clock only resolve a column when it lands inside a
displayed segment (a dropped gap or zero-width segment is a hole where no marker is drawn).

Labels are placed once per distinct activity, the label's colour swatch over **one** of the activity's
segments (text flows to the swatch's right), with **the text length itself a placement variable**: a
label that would block its neighbour is *shortened*, not dropped. `fit_legend` decides which activities
are shown (dropping the least-present only when even minimal labels can't all fit the width; widths in
display cells via a pure codepoint-width table mirroring `strdisplaywidth`, so double-width CJK/emoji is
budgeted correctly). Then, over the product of each survivor's occurrence choices (bounded — the busiest
label's narrowest occurrences are trimmed first), the layout is scored **lexicographically**: (1) fewest
labels dropped, (2) fewest characters hidden (prefer full text), (3) lowest Σ rank of the anchored
occurrence (rank 0 = the activity's longest segment), (4) keep the most-present activity. Each assignment
is placed in three passes: (a) pack every label at its shortest still-distinct form (swatch overlapping
its block, clearing the previous label) so a label is dropped only when even that floor cannot fit;
(b) right-to-left, grow each shown label's text into the room a **right-aligned** right neighbour leaves
(past the left labels' reserved floors) — so free bar space flows left to whoever can still use it,
rather than being stranded behind a right label pinned near its centre; (c) with lengths now fixed,
position the swatches — each centred on its block, pushed off-centre only as far as a neighbour genuinely
needs the room. A label is never shown off its own colour. Integer arithmetic, fully deterministic.

The strip is a real reserved-height window, not virtual lines, so it must not outlive its
log window or block `:q`. Closing a strip inside `BufWinLeave` would abort the quit, so
teardown runs from `QuitPre` and (deferred) `WinClosed`, never during the close. Strips are
keyed by their owner (log) *window*, so navigating between daylog files in one window reuses
the strip; opening the split sets a targeted `eventignore` so it cannot recurse back into the
highlighter via the ftplugin's `BufWinEnter`.

## Usecases, edit scripts, and the shell

A usecase is a pure command operation: it accepts plain Lua input, calls
context/analyze/body/summary helpers, and returns an edit script or an error
message — never the Neovim API.

```lua
local result, err = append_summary.run(lines)
-- success: { edits = { { start_index = 4, end_index = 4, lines = { ... } } } }
-- failure: nil, "daylog: ..."
```

An edit script is the project's core data structure:

```lua
{ start_index = 1, end_index = 3, lines = { "08:00 plan", "09:00 done" } }
```

`init.lua` applies it with `nvim_buf_set_lines(0, start_index, end_index, false,
lines)`. Indexes are zero-based to match the Neovim buffer API.

`init.lua` is the Neovim shell: it registers filetype support and user commands,
reads buffer lines, cursor row, and current time, expands configured daybook
paths before calling pure daybook helpers, calls usecases, applies edit scripts,
applies highlight spans as extmarks, and shows warnings. It contains no log
semantics.

The shell is a thin *layer*, not a single file. Alongside `init.lua` (setup, autocmds,
edit-script application), the code that touches Neovim, IO, or UI is its sibling
command/edit modules (`commands`, `buffer`, `report`, `rename`, `map`, `pick`), the
daybook/clock IO (`daybook_io`, `current_time`), `filetype` (registers the filetype),
`health.lua` (the `:checkhealth` probe), `ftplugin/daylog.lua` (attaches the highlighter),
and the sources shell modules (`sources/http`, `sources/sync`, and the top-level
`telescope`). Each shell module's header says so; everything else -- the semantic core, the
source providers, and the highlighter -- stays pure. See below.

## Sources

External work-item sources (e.g. Azure DevOps) let `:Daylog insert <source>` pick a
tracker item and insert it, while keeping the same pure-core discipline: the
provider logic is pure and only IO/UI is shell.

A source is a plain table implementing a small contract:

```text
fetch(cb)            -- async: cb(items|nil, err); the default item set
format_item(item)    -- item -> picker display line
format_items(items)  -- optional: aligned display lines for the whole list
to_entry_text(item)  -- item -> inserted activity text
search(query, cb)    -- optional: async live search (cb(items|nil, err))
```

An item is `{ id, title, type?, state?, url? }` (`id`/`title` required). Built-in
source types are declared in `setup{ sources = { ... } }`; custom sources register
directly via `require("daylog.sources.registry").register(name, source)`, which
validates the contract.

Layering:

```text
sources/registry.lua      pure   contract, name registry, register/validate
sources/cache.lua         pure   cache envelope codec + TTL staleness
sources/picker.lua        pure   live-search helpers (align / merge / display / should_query)
sources/azure_devops.lua  pure   the ADO provider (pure via injected deps)
sources/http.lua          shell  the only networked file: curl via jobstart
sources/sync.lua          shell  on-disk cache + lazy-TTL / :Daylog sync refresh
telescope.lua             shell  optional live picker (top-level; :Daylog insert + :Daylog rename)
```

The ADO provider stays pure through **dependency injection**: `init.lua` hands it
`{ transport, json, token_resolver }`, so all HTTP/JSON/secret access goes through
injected deps and the provider is unit-tested offline with a fake transport.

Pick-time is offline and synchronous: read the per-source JSON cache
(`stdpath('cache')/daylog/sources/<name>.json`) and open the picker. The cache is
refreshed only by the occasional sync (in the background when stale, or via
`:Daylog sync`), never in the hot path. The PAT is resolved lazily by
`token_resolver` and never written to the cache.

Insertion still flows through the pure `usecases/insert_entry` + an edit script, and
`insert_entry` runs the text through `entry.sanitize_text` so a work-item title can
never inject trailing `#tag` / `@location` / `!L` metadata -- no source has to
remember to do it.

Telescope is optional. `:Daylog insert <source>` uses `vim.ui.select` (which any
ui-select provider upgrades) by default; when Telescope is installed and the source
implements `search`, it opens the live picker that searches the whole tracker as you
type. Live whole-project search is the only Telescope-exclusive capability --
everything else is picker-agnostic.

## Error philosophy

Prefer explicit syntax over silent semantic corruption. A rewrite emits `#-` / `@-`
when it returns to untagged or unlocated work — rather than silently turning
untagged work into `#ClientA` or no-location work into `@office`.

## Testing expectations

Core areas under test: syntax parsing; sticky tag/location inheritance; `#-` and
`@-`; blank entries (uncounted time); summaries and quantization (including `q=1` exactness); tag
and location totals; copy, order, repeat (incl. from a summary row), rename, and
insert behavior; equal-timestamp insertion; quantized summary invariants; and the
parser-driven highlight spans (`tests/highlight.lua` is a contract test that the
highlighter agrees with the grammar `document.lua` parses).

Tooling and the local gate (`just install`, `just check`, `just --list`, and the
raw headless test/health commands) are documented in the README and `justfile`.

## Future ideas

- richer reports
- validation command
- more filetype niceties
