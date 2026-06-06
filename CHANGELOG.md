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
