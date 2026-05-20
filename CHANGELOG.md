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

- Added trailing `!L` entry syntax for intervals that were logged externally.
  The flag is preserved by source rewrites, stays non-sticky, and formats after
  trailing tag and location tokens.
- Added logged-aware summaries and reports. Main summary rows now split by
  logged state, render logged rows with trailing `!L`, and add logged versus
  unlogged totals for workday-eligible intervals.
- Added optional `journal` configuration and `:WorklogToday` to open today's
  dated `.wkl` file, create parent directories, and initialize missing or empty
  journals with configured defaults and the current time.
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

### Changed

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
