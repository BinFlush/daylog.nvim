# Changelog

All notable user-facing changes to this project are documented here.

## Compatibility policy

`main` is the active development branch and may receive ongoing changes.

Tagged releases are the recommended compatibility points for users who need
reproducible behavior.

The `.wkl` format is intended to be stable. Changes that alter the meaning of
existing valid worklogs, summary totals, sticky metadata, or quantization are
treated as breaking changes and called out clearly.

Versioning loosely follows SemVer, with compatibility focused on `.wkl` semantics:

- Patch releases fix bugs without intentionally changing behavior for valid files.
- Minor releases add compatible syntax, commands, or reporting features.
- Major releases may change how existing valid `.wkl` files parse, summarize, or render.

## Unreleased

### Added

- Added `duration=decimal|hhmm` as a block-local worklog header option for
  summary duration rendering.

### Changed

- Focused `:checkhealth worklog` on runtime plugin integration and split
  contributor checks into static and Neovim-dependent groups.
- Documented Neovim 0.8.0 as the minimum supported version and kept CI focused
  on the supported floor plus newer releases.

### Fixed

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
