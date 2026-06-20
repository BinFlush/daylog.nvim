# Changelog

All notable user-facing changes to this project are documented here.

## Compatibility policy

`main` is the active development branch and may receive ongoing changes.

Tagged releases are the compatibility points for users who need reproducible
`.wkl` parsing, summaries, and rendering.

`worklog.nvim` is pre-1.0, so breaking syntax or semantic changes may still
happen, but they are called out clearly in this changelog.

- The project aims to preserve existing valid `.wkl` files where practical.
- Unknown or unsupported header options are reported as diagnostics, not
  silently ignored.
- Patch releases may change derived results when they fix miscomputed
  behavior; those changes are documented here.
- Compatibility applies to worklog blocks and their semantics. Generated
  summary text is derived output, not canonical source data.

## Unreleased

### Changed

- **Renamed the plugin to Blotter** (breaking). An entry is now a
  *blot*, a block of blots is a *blotter*. Files use the `.blot` extension (was
  `.wkl`) with `--- blots ... ---` block headers (was `--- worklog ... ---`), and
  the filetype is `blotter` (was `worklog`). Commands are split by scope: item
  actions take the `Blot` prefix (`:BlotInsert`, `:BlotRepeat`, `:BlotRename`,
  `:BlotLog`, `:BlotBalance`) and journal/report/housekeeping actions take the
  `Blotter` prefix (`:BlotterToday`, `:BlotterInit`, `:BlotterNextDay`,
  `:BlotterPrevDay`, `:BlotterWeek`, `:BlotterDays`, `:BlotterCopy`,
  `:BlotterOrder`, `:BlotterRefresh`, `:BlotterSync`). The Lua module is
  `require("blotter")`, health is `:checkhealth blotter`, and messages are
  prefixed `blotter:`. Update your config to match: change
  `require("worklog").setup(...)` to `require("blotter").setup(...)` (the option
  keys are unchanged), point your plugin spec at the renamed repo, and rename any
  `:Worklog*` keymaps to their `:Blot*` / `:Blotter*` equivalents. The old names,
  the old format, and `.wkl` files are not supported. Convert an existing journal
  tree with
  `scripts/migrate-to-blotter.sh <journal-root>` — a dry run by default; pass
  `--apply` to perform it (and `--backup` to keep `.wkl.bak` copies). It rewrites
  each `--- worklog ... ---` header to `--- blots ... ---` and renames `.wkl` →
  `.blot`.

### Added

- `:BlotRename` can replace an activity with a tracked work item: when the
  cursor is on an activity row and a source is configured, the rename picker also
  lists and live-searches that source's items (alongside the merge candidates), and
  picking one renames the activity to the item's blot text (`{id} {title}`), just
  like `:BlotInsert`. With one source it is offered automatically; with several,
  name it as the argument (`:BlotRename {source}`, tab-completed). An argument
  that is not a source name still renames directly to that text. Tag/location rows
  are unaffected.
- `:BlotBalance [steps]` manually balances summary rounding by a signed number
  of `q=` steps (default `+1`, `0` clears). Largest-remainder rounding can leave a
  day — and therefore a week — a step or two short of a clean total (e.g.
  `39.75h (+15m)` when the true total is `40.00h`); this nudges it. With the cursor
  on a summary row the least-error contributing blot is rounded further (the
  workday/activity total scopes all work, a main row its activity, a
  tag/location/logged total that group); with the cursor on an blot that blot is
  nudged directly. The chosen blots gain a non-sticky `round±N` marker, the one
  summary is rebuilt, and the marker shows on every affected summary row so it
  stays visible and adjustable (re-run to add more, opposite sign to undo, `0` to
  clear). Because a week report sums its days without re-rounding, balancing one
  day reconciles the week total automatically. Every section still foots to its
  (shifted) total; a blotter with no marker is byte-for-byte unchanged. The new
  `BlotterNudge` highlight group colours the marker; `utc±H` offsets now also
  highlight as a distinct bright group (`BlotterOffset` → `Type`) rather than as a
  comment. See `:help blotter-balance`.
- UTC-offset markers (`utc±H[:MM]`) record when the clock moves under you while
  travelling or across a DST flip — a third sticky dimension alongside `#tag` and
  `@location`. The sign is required (a bare `utc` stays plain text), so the marker
  is invisible until used; it is declarable on the header as a base, inherited
  until the next `utc` token, and has no clear form. Durations and timestamp
  ordering reconcile in effective UTC time (`local - offset`) — so an interval
  spanning a westward move counts forward, not backwards — while the displayed
  times, the `24:00` boundary, carryover, and the journal date stay the written
  local clock. A blotter with no `utc` marker is byte-for-byte unchanged. A new
  `defaults.utc` (`'+2'`, `'-4'`, `'+5:30'`, or `'auto'`) stamps a base offset
  into headers created by `:BlotterToday`. See `:help blotter-utc-offset`.
- `:BlotRename [name]` renames what the summary row under the cursor stands
  for, propagating into the attached blotter and rebuilding the summary: a main
  row renames the activity text of its source blots, a tag-total row renames
  that `#tag`, and a location-total row renames that `@location`. Tag/location
  renames rewrite only the header token and the explicit tokens that named the
  old value, so sticky inheritance is preserved and unrelated lines are left
  untouched. Renaming to a name that already exists merges the two; with no
  argument the command offers a picker of the other same-kind values to merge
  into (a Telescope picker that also lets you type a fresh name via `<C-e>`, or a
  `vim.ui.select` list plus a "type a new name" blot), falling back to a plain
  prompt when there is nothing to merge into.
- `:BlotRepeat` now works from the summary: with the cursor on a main summary
  row, it repeats the latest source blot that produced that row, so an activity
  can be resumed straight from the summary (including across days). Tag, location,
  and total rows are not eligible. Repeating a timestamped blot is unchanged.
- Week/days reports (`:BlotterWeek` / `:BlotterDays`) now show each day's own `q=`
  bucket in its section header (e.g. `--- day summary 2026-05-18 q=30 ---`), so a
  period mixing different quanta stays legible. The aggregate summary header is
  unchanged.
- The `:BlotterWeek` / `:BlotterDays` report buffers are now syntax-highlighted,
  including the labeled multi-day section headers and their duration rows.
- `:BlotterInit [offset]` creates (or opens) the journal file for an arbitrary day
  (today plus a signed offset), scaffolding the directory, default header, and an
  empty summary when the day is new. Unlike `:BlotterToday` it never stamps the
  current time, so it is the way to start a past or future day.
- `:BlotRename` now works on a `:BlotterWeek` / `:BlotterDays` report: with the
  cursor on an aggregate row it renames the item across every day of the period; on
  a per-day row, in that one day's file. It rewrites each affected day by value
  (skipping days that lack the item) after a confirmation listing the files --
  editing an open buffer in place or writing to disk -- then rebuilds the report.
  Activities, tags, and locations are all renamable, mirroring the single-day
  rename; a source replacement is not offered from a report.

### Changed

- Syntax highlighting is now derived from the blotter parser and applied as
  extmarks, replacing the separate Vimscript syntax file. Highlighting therefore
  always matches how the plugin parses a file (one grammar, not two) and no longer
  depends on `:syntax on`. The highlight group names are unchanged (`BlotterTag`,
  `BlotterDuration`, `BlotterOoo`, ...), so existing `highlight` overrides keep
  working. A duration / `(+Nm)`-shaped line is highlighted as a summary row only
  inside a generated summary section; the same shape written as a free comment
  (outside a section) stays a note, so a comment can't masquerade as a summary item.
  Generated section headers (`--- summary ---`, `--- tags ---`, `--- totals ---`,
  ...) now link to `NonText` instead of `Comment`, so they read as a muted but
  distinct colour rather than blending into notes; override `BlotterBlockHeader` to
  taste.
- The `:BlotInsert {source}` picker now renders work items as aligned columns
  -- the id, `[type/state]`, and (for multi-project sources) the project line up,
  with the variable-width title last -- instead of a ragged trailing column when
  titles differ in length. Sources can opt in via a new optional `format_items`
  contract method (`blotter.sources.picker.align` does the column padding).
- `:BlotLog` now shares the same summary-row resolver as `:BlotRename` and
  `:BlotRepeat`, so its staleness and ambiguity checks are identical. One
  consequence: a main summary row whose rendered line is byte-identical to another
  summary line (e.g. an activity literally named `workday`, matching the workday
  total) is now refused as ambiguous rather than logged.
- `:BlotterNextDay` / `:BlotterPrevDay` now jump to the next/previous day that
  actually has a blotter, skipping empty days, and warn (staying put) when none
  exists in that direction; `[count]` steps over that many blotters. Previously
  they stepped exactly one calendar day and opened an empty buffer for a missing
  day. Use `:BlotterInit` to create a day that does not exist yet, or
  `:BlotterToday <offset>` for an exact-date jump (unchanged).

### Fixed

- Refreshing a blotter whose summary shrank to (almost) nothing -- e.g. after
  deleting all but one blot, leaving no completed interval -- no longer stacks a
  second summary below the stale one. The summary region is now located by the
  union of content alignment and structural recognition, so refresh replaces the
  existing summary in place, and a buffer already jumbled by the old behavior
  collapses back to a single summary on the next refresh. Stray content left
  *inside* a generated section (a line with no blank above it, e.g. a hand-typed or
  pasted row in the totals section) is part of the summary and is regenerated away;
  a note written *after* the summary (below a blank) is left untouched.
- Decimal-hour (`d=dec`) summary and report rows now always sum to the displayed
  section total. Each row was rounded to two decimals independently, so several
  fractional rows could read e.g. `0.99h` against a `1.00h` total; the displayed
  values are now distributed with the same largest-remainder method used for
  minute quantization, so every visible column foots. `d=hm` is exact and
  unchanged, and footing values render identically to before.
- `:BlotInsert {source}` now refuses up front when the cursor is outside a
  blotter, with the same error as plain `:BlotInsert`, instead of opening the
  picker and only failing after an item is chosen.
- `:BlotRepeat` on yesterday's blotter now brings the cursor blot into today
  when today already exists, instead of refusing with "today's blotter already
  exists". Previously a still-running task at the end of yesterday routed the
  command through the past-midnight carryover, which refuses once today exists;
  it now falls back to the normal cross-day repeat like any other past day.

## 0.7.0 - 2026-06-14

### Added

- External work-item sources. Configure `sources` in `setup{}` (Azure DevOps is
  built in) and run `:WorklogInsert {source}` to pick a work item from a fuzzy
  picker and insert it as `{id} {title}` at the current time. The picker uses
  `vim.ui.select`, so Telescope / fzf-lua / snacks / mini.pick take over its UI
  when installed. Picking reads a per-source local cache, so it is instant and
  works offline; `:WorklogSync [source]` and a periodic TTL refresh update the
  cache. Syncing needs the `curl` executable. The Personal Access Token is a
  function resolved only at sync time and never written to the cache. Plain
  `:WorklogInsert` (no argument) is unchanged.
- Live work-item search. With Telescope installed and a source that supports it,
  `:WorklogInsert {source}` searches the tracker as you type (debounced), showing
  your cached items at an empty prompt; without Telescope it uses the offline
  `vim.ui.select` cache picker. The Azure DevOps source searches work-item titles
  project-wide; custom sources opt in via `search(query, cb)`. Live search waits
  until the prompt reaches `min_query` characters (default 3; set to 1 for
  search-on-first-keystroke) so short prompts only filter the cached set, shows at
  most 200 matches with a "showing first N of M" notice when truncated, and
  reports a `worklog:` warning if a search fails.
- Documented the custom-source contract for third-party integrations
  (`:help worklog-custom-source`) with callback/item shapes and a worked example.
  Inserted activity text is now sanitized centrally, so any source is safe from
  trailing-metadata injection without handling it itself, and
  `require("worklog.sources.registry").register` validates a source up front.
- Azure DevOps setup guide (`docs/azure-devops.md`), linked from the README:
  creating a Work Items (Read) PAT, storing it (`pass` / env var / `0600` file),
  wiring `token`, and troubleshooting.
- Azure DevOps `projects` option: set a list of projects instead of a single
  `project` to search a chosen subset across the organization at once. Results
  are labelled by project and `{project}` is available in the insert template.
  Mutually exclusive with `project`, `query`, and `query_id`.

### Changed

- The day-navigation commands (`:WorklogPrevDay`, `:WorklogNextDay`, and
  `:WorklogToday` with a nonzero offset) refuse to leave today while its worklog has
  errors (e.g. out-of-order entries), so the active day is not silently abandoned in a
  broken state; the problems are shown as diagnostics. Fix them to navigate.

### Fixed

- `:WorklogRepeat` from another day is robust when bringing the activity into today: it
  reports the problem and stays on the browsed day when today's worklog is broken or the
  browsed buffer is unsaved (instead of a raw error), and a whitespace-only today is
  initialized fresh.

## 0.6.0 - 2026-06-07

### Added

- `:WorklogRepeat` on another day's journal file brings the activity under the
  cursor into today's worklog at the current time (opening today if needed), instead
  of refusing — handy when reviewing a past day with `[w` / `]w`.

### Fixed

- Editing or deleting a generated summary's section header (`--- summary … ---`,
  `--- totals ---`, …) no longer spawns a duplicate summary. The summary is located by
  aligning the buffer against its expected content, so any edit to it — header or row —
  is reverted in place on the next refresh.

### Changed

- Worklog header options now use short keys: `quantize=` → `q=`, and
  `duration=decimal|hhmm` → `d=dec|hm`. The summary header echoes them as a
  read-only banner — `--- summary q=15 d=dec ---` — regenerated from the worklog
  header on refresh. **Breaking:** update existing files (`quantize=`→`q=`,
  `duration=`→`d=`, `decimal`→`dec`, `hhmm`→`hm`); an old option now reports an
  unknown-option diagnostic.
- The two summary types are now one. "Exact" is just `q=1`; generated
  summary headers drop their kind word (`--- summary exact ---` and
  `--- summary quantized ---` both become `--- summary q=<n> d=<fmt> ---`) and every row shows
  its rounding error, including `(+0m)`. Existing `.wkl` files load unchanged —
  their summaries regenerate in the new form on the next refresh.
- Every worklog now carries a summary: `:WorklogCopy` appends one to the copy,
  matching `:WorklogToday`, and `auto_summary` defaults to `change` so it stays
  live. Set `auto_summary = "off"` to opt out.
- A deleted summary is restored automatically: the summary refresh (and
  `:WorklogRefresh`) re-creates a missing summary for any valid worklog, so every
  valid worklog stays summarized.

### Removed

- `:WorklogSummarize` and `:WorklogQuantSum`. A worklog's summary is now created
  by `:WorklogToday` / `:WorklogCopy` and kept current automatically; use
  `quantize=1` in the worklog header for exact (unrounded) figures.
- `:WorklogCheck`. Its diagnostics are already published live by the summary
  refresh.
- The `:WorklogNew` command binding. `:WorklogToday` still creates and stamps the
  day; arbitrary `.wkl` buffers take a `--- worklog ---` header typed by hand.

### Development

- Added a release workflow that publishes a GitHub Release from the matching
  `CHANGELOG.md` section when a `vX.Y.Z` tag is pushed (or via manual dispatch),
  plus a `just release X.Y.Z` recipe that bumps the changelog, commits, and tags.

## 0.5.0 - 2026-06-07

### Added

- `:WorklogWeek` and `:WorklogDays` reports refresh while open as their source
  files and buffers change, following `auto_summary` — matching how in-file
  summaries update.

### Changed

- `:WorklogOrder` now warns when sorting sets an entry's tag or location from its
  original order, so order-dependent metadata is never re-attributed silently.

### Fixed

- `:WorklogToday` reuses an open but unsaved today buffer when reopened after
  navigating to another day, instead of appending a duplicate worklog.
- `:WorklogWeek` and `:WorklogDays` include unsaved edits from open journal
  buffers in their summaries, instead of reading only the saved files.
- Past-midnight carryover recognizes an open but unsaved today worklog and
  refuses, as it already does for one saved on disk.
- `:WorklogRepeat` and past-midnight carryover no longer silently change the
  following entry's tag or location when inserting an entry before it.
- `:WorklogWeek` and `:WorklogDays` skip a day that has notes but no worklog
  block (e.g. a "day off" note) instead of failing the whole report.
- Past-midnight carryover refreshes the previous day's summary before saving it,
  so the carried-over 24:00 close is reflected on disk instead of a stale total
  (it previously refreshed only under `auto_summary = "save"`).
- Past-midnight carryover no longer appends a second 24:00 (corrupting the file)
  when the previous day's final entry is already a 24:00 boundary entry.
- The `quantize=` header option rejects non-integer values (`inf`, `0x10`, `1e2`,
  `5.0`, `+5`) with a diagnostic instead of silently accepting them; `quantize=inf`
  previously produced NaN summaries.
- `:checkhealth worklog` no longer resets the live configuration (journal,
  defaults, `auto_summary`) and its refresh autocmds — the probe is read-only now.
- A relative `journal.root` is absolutized, so the time guard and past-midnight
  carryover recognize journal files instead of silently disabling themselves.
- A `--- worklog ---` header is recognized only when `worklog` is a whole word, so
  `--- worklogs ---` and `--- worklog#sales ---` read as generic block headers
  (matching the highlighter) instead of malformed worklog headers.
- `duration=hhmm` summary rows highlight as durations instead of as entry
  timestamps or dimmed notes, including exact two-digit-hour rows (e.g.
  `16:00 workday`), which are disambiguated from entries by their summary-block
  context.
- `:WorklogInsert` places a new entry right after the last entry, keeping any
  trailing blank lines as a gap before the summary instead of inserting past them
  (also applies to `:WorklogRepeat` and the past-midnight `24:00` close).

## 0.4.0 - 2026-05-24

### Added

- An invalid worklog (out-of-order timestamps, an invalid entry, or a
  missing/broken header) is now reported as a buffer diagnostic instead of
  stalling its summary silently, whether or not it has a summary. The diagnostic
  clears as soon as the worklog is valid again, however it was fixed.
- `:WorklogCheck` now publishes every problem as a buffer diagnostic and shows a
  one-line summary, instead of reporting only the first problem.

### Changed

- Day navigation no longer creates or initializes files. `:WorklogNextDay` /
  `:WorklogPrevDay` (`[w` / `]w`) and `:WorklogToday` with a nonzero offset now
  only open the target day — an existing file, or an empty unmodified buffer when
  none exists — so they never write a header, create a directory, or leave a
  modified buffer. Only `:WorklogToday 0` still creates and stamps today.

### Fixed

- Syntax highlighting now mirrors the parser: out-of-range times, repeated entry
  metadata, and invalid or duplicate worklog header options are no longer
  highlighted as valid.

## 0.3.0 - 2026-05-24

### Added

- Added trailing `!L` entry syntax for intervals that were logged externally.
  The flag is preserved by source rewrites, stays non-sticky, and formats after
  trailing tag and location tokens.
- Added logged-aware summaries and reports. Main summary rows now split by
  logged state, render logged rows with trailing `!L`, and add logged versus
  unlogged totals for workday-eligible intervals.
- Added `:WorklogLog` to toggle the logged state of the main summary row under
  the cursor: it marks (or unmarks) the contributing source entries with `!L`
  and rebuilds the worklog's single summary. Refuses `#ooo` rows and stale
  summary rows that no longer match the recomputed summary.
- Added `:WorklogRefresh` and the `auto_summary` setup option to keep summaries
  in sync with their entries. Refresh rebuilds every existing summary in the
  buffer (every worklog, not just the active one) and never creates or removes
  one. `auto_summary` runs it automatically: `off` (default), `change`, `idle`,
  or `save`.
- Added optional `journal` configuration and `:WorklogToday` to open today's
  dated `.wkl` file, create parent directories, and initialize missing or empty
  journals with configured defaults, the current time, and a quantized summary.
- Added `:WorklogWeek` to open a scratch weekly report from journal-backed
  daily worklogs by recomputing each day's quantized summary from its latest
  worklog block and then summing those daily quantized results.
- Added `:WorklogDays {count}` to open a scratch range report for the last N
  journal dates using the same daily-first quantization and strict validation
  rules as `:WorklogWeek`.
- Added `:WorklogWeek!` and `:WorklogDays! {count}` to open compact journal
  reports that omit the per-day review sections and show only the aggregate
  weekly or range summary.
- Added optional signed day offsets to `:WorklogToday [offset]`. `0` keeps the
  current behavior, while nonzero offsets open nearby dated journal files and
  initialize missing or empty files with only the configured worklog header.
- Added `:WorklogNextDay [count]` and `:WorklogPrevDay [count]` to step between
  dated journal files relative to the file in the current buffer (default one
  day, `count` steps further), falling back to today when the buffer is not a
  canonical journal file. Unlike `:WorklogToday`, stepping is navigation only and
  never inserts the current time, so repeated presses walk through days.
- Added a `24:00` end-of-day boundary timestamp that closes a worklog block's
  final task at midnight, contiguous with the next day's `00:00`. It is valid
  only as the final entry; a `24:00` entry followed by another timestamped entry
  is reported as a diagnostic.
- Added past-midnight carryover for `:WorklogInsert` and `:WorklogRepeat`. When
  the buffer is yesterday's journal file and a task is still running, the command
  offers to close that day at `24:00`, open (creating if needed) today's journal
  file, continue the task from `00:00`, then apply the command at the current
  time.

### Changed

- A worklog now keeps a single summary, either exact or quantized.
  `:WorklogSummarize` and `:WorklogQuantSum` replace the existing summary in
  place instead of appending (running one over the other switches the kind), so
  a worklog no longer accumulates multiple summary blocks. The summary is
  regenerable derived output; keep notes on entries rather than inside it.
- `:WorklogInsert` and `:WorklogRepeat` now refuse to stamp the current time
  into a journal file dated for another day. The guard stays silent on buffers
  that are not canonical journal files, so the plugin still works on arbitrary
  `.wkl` files.

### Fixed

## 0.2.0 - 2026-05-17

### Added

- Added `:WorklogNew` to create a new worklog block at the end of the buffer.
- Added optional `worklog.setup({ defaults = ... })` header defaults for new
  worklogs: `tag`, `location`, `quantize_minutes`, and `duration_format`.
- Added `duration=decimal|hhmm` as a block-local worklog header option for
  summary duration rendering.

### Changed

- Summary rendering can now vary per worklog via `duration=decimal|hhmm`.
  Users who need stable rendered summary text should pin a release tag and keep
  `duration=decimal` unless they explicitly want `hhmm` output.
- Focused `:checkhealth worklog` on runtime plugin integration and split local
  contributor checks into `just static-check`, `just nvim-check`, and
  `just check`.
- Documented Neovim 0.8.0 as the minimum supported version.

### Development

- Added GitHub Actions CI for static checks and Neovim-dependent checks across
  the supported floor and newer releases.

## 0.1.0 - 2026-05-17

### Added

- Added structured `.wkl` worklog parsing.
- Added sticky `#tag` and `@location` metadata.
- Added `#-` and `@-` clear-token support.
- Added `#ooo` out-of-office handling, counted as activity but excluded from workday totals.
- Added exact summaries with item, tag, location, activity, and workday totals.
- Added quantized summaries with configurable `quantize=<minutes>` buckets.
- Added Neovim commands:
  - `:WorklogInsert`
  - `:WorklogRepeat`
  - `:WorklogCopy`
  - `:WorklogOrder`
  - `:WorklogSummarize`
  - `:WorklogQuantSum`
  - `:WorklogCheck`
- Added `.wkl` filetype detection.
- Added Vim help documentation.
- Added `:checkhealth worklog`.

### Development

- Added project tooling through `just`, StyLua, luacheck, tests, health checks, compatibility fixtures, and helptag checks.
