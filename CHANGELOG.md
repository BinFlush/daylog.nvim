# Changelog

All notable user-facing changes to this project are documented here.

## Compatibility policy

`main` is the active development branch and may receive ongoing changes.

Tagged releases are the compatibility points for users who need reproducible
`.day` parsing, summaries, and rendering.

`daylog.nvim` is pre-1.0, so breaking syntax or semantic changes may still
happen, but they are called out clearly in this changelog.

- The project aims to preserve existing valid `.day` files where practical.
- Unknown or unsupported header options are reported as diagnostics, not
  silently ignored.
- Patch releases may change derived results when they fix miscomputed
  behavior; those changes are documented here.
- Compatibility applies to log blocks and their semantics. Generated
  summary text is derived output, not canonical source data.

## Unreleased

### Added

- **The commit-audit hook flags corrupted commits with their own `daylog-corrupt/<date>-<hash>` tag.** A
  daybook commit that leaves any `.day` file carrying a daylog warning — a broken log in any block, now
  including the footing/logging conflicts the previous check missed, not just structural problems — is
  tagged separately from the `daylog-other-day/` alarm (a commit can carry both). Detection uses the same
  warning source the buffer surfaces, spanning every log block in the file.

### Changed

- **Logged markers now require their brackets: `!S[]` is the only unnamed form.** The name-set brackets
  were previously optional — a bare `!S` and an explicit `!S[]` both meant "logged, unnamed." They are now
  mandatory: `!S[]` (optionally `!S[]60` when frozen, or `!S[names]`) is the sole logged form at every
  level, and a plain `!S` with no brackets is ordinary activity text, not a marker. The writer has always
  emitted the bracketed form, so files daylog has rewritten are unaffected; only a hand-written or
  pre-0.16.0 bare marker changes meaning, dropping out of the summary as plain text. This revokes the
  0.16.0 note that bare markers still parse identically. (Syntax change.)

- **Export is now a full projection of the summary block.** The CSV/JSON export used to emit only the
  per-activity (`!S[]`) rows; it now dumps every summary section, tagged by a new `level` column
  (`activity` / `tag` / `location` / `workday`), so tag, location, and workday logging (`!T[]`/`!L[]`/`!W[]`) is
  exported too. Each row carries its recipients (`logged_to` — the marker's names; CSV comma-joins, JSON is
  an array) and the residual alongside the billed `minutes`: `unrounded_minutes` (real elapsed) and
  `error_minutes` (the `(±Nm)` rounding delta, can be negative). A partially logged row exports as two rows
  (the reported slice + the unlogged remainder). Numeric columns skip the CSV formula guard, so a negative
  `error_minutes` stays a number. Each level is a full partition of the counted day — filter by `level`,
  don't sum across them.
- **Export `hours` now foots to the workday.** The column was rounded per row (three 20-minute activities
  summed to 0.99h against a 1.00h workday); it is now footed with the same largest-remainder distribution
  the report uses, so each level's hours sum to the day.

### Removed

- **Removed `:Daylog migrate` and `scripts/migrate-to-daylog.sh`.** The one-time v0.1.x `!L`→`!S`
  logged-marker migration and the standalone legacy-format import script (`*.wkl`/`*.blot` → `*.day`) were
  dead weight; the migration in particular could no longer see a bare `!L` once brackets became mandatory.
  Convert any pre-multi-level or legacy-format logs before upgrading.

### Fixed

- **Report and export refuse an absurd day count instead of freezing.** `:Daylog report 20200101` (a
  plausible typo for `2020-01-01`) parsed as a 20-million-day count and materialized the list
  synchronously, hard-freezing Neovim. The resolved span is now capped (~100 years) with a clear warning.
- **A report fan-out or export can no longer truncate a `.day` file.** `:Daylog log`/`rename` across a
  multi-day report, and `:Daylog export`, wrote files with a plain `writefile` (`O_TRUNC`) — an
  interrupted write (disk full, crash) truncated the file, and a mid-fan-out failure left some files new
  and some old. Writes are now atomic (temp + rename) and the fan-out is all-or-nothing: on any failure
  every file is left untouched.
- **A `:Daylog` command that hits an unexpected error now warns instead of dumping a raw traceback** (the
  command dispatch and the auto-summary report refresh fail soft, matching the summary refresh).
- **Source robustness.** A structurally-corrupt source cache self-heals (drops malformed items and
  re-syncs) instead of crashing the picker; a custom source whose `fetch` never returns no longer wedges
  its sync forever (a watchdog clears it); confirming an empty live-search list leaves a bare timestamp
  instead of dropping the insert; and the Azure DevOps token is written to a `0600` file before it ever
  touches disk.
- **`:Daylog split` no longer deletes an entry logged at the same minute as the next.** Two entries
  sharing a timestamp make the first interval zero-duration; splitting the activity dropped that entry's
  line and the sticky `#tag`/`@location`/`utc` the next entry inherited, desyncing the summary. The entry
  and its metadata are now preserved.
- **`:Daylog insert <source>` keeps a drifted UTC offset while you keep typing.** With `auto_timezone` on
  and the live zone drifted, the inserted entry trails a `utc±H` token and the cursor landed after it, so
  continued typing swallowed the offset into the description and silently shifted the interval. The cursor
  now lands before the token, like `:Daylog insert now`.
- **A frozen logging value larger than a day is rejected.** A hand-edited value over 1440 minutes (e.g.
  `!S999999990`) drove a multi-second refresh stall and printed absurd totals; it is now an invalid entry.
- **Cross-cutting logging that can't honor a per-location `!S` is flagged, not silently mis-split.** When
  the same activity spanned two locations each with their own `!S`, a `!T`/`!L` that undercut their sum
  could pull one location's slice below its committed value while the other location's surplus masked it —
  the summary footed, but the per-slice value drifted from the marker, so a later `:Daylog log`/`balance`
  could freeze the wrong value. It now falls back to the honest durations and raises the contradiction
  warning.
- **`:Daylog split` no longer silently drops non-`!S` logging.** Splitting an activity whose entries
  carried a committed `!T`/`!L`/`!W` marker (but not `!S`) erased the commitment; it is now refused, like an
  `!S`-logged activity.
- **A stray `round±N` marker no longer leaks onto tag/location/workday rows** of an over-committed cell,
  where the nudge is inert (it disagreed with the main row and could raise a spurious below-zero warning).
- **Fan-out writes are guarded.** A `:Daylog rename` / `log` across day files that hit an unwritable file
  now warns instead of throwing and half-applying the change.
- **Clearer messages:** an open-ended report range that crosses its resolved extreme (`..2020`) says
  "range start is after end", not "no daybook logs found"; a cursor on a summary header/blank no longer
  reports the summary as stale; a `9:75`-style near-miss reports "invalid time" rather than suggesting the
  invalid `09:75`.
- **`setup({ defaults = { quantize_minutes = N } })`** is capped at 1440 so `:Daylog new` can't scaffold a
  header the analyzer rejects.
- **`:Daylog sync`** warns when a source query was truncated (more than 200 items) instead of silently
  caching a subset.
- **`:Daylog! insert <source>`** opens that source instead of silently dropping it for the unified picker.
- Public `require("daylog").next_day(0)` / `prev_day(0)` now step once instead of no-op-warning; the time
  bar counts emoji width correctly (no dropped legend labels); the commit-audit hook installer is
  worktree-safe and warns on Neovim < 0.9.
- **Prose starting with a summary section word no longer fragments a log.** A note like
  `--- tags to follow up ---` or `--- summary of my week ---` inside a log was parsed as a structural
  header, splitting the entries after it into a separate rollup. A first-position section word is now a
  boundary only when it stands alone or carries its generated options; multi-word prose is a plain note.
  A single-word legacy `--- summary <type> ---` (e.g. `--- summary exact ---`) still reclaims.
- **A committed tag/location renders its logged and remainder slices adjacently.** The tag and location
  sections were sorted by each slice's own duration, so an unrelated cell of intermediate size could
  appear between the two halves of one `#tag`/`@location`; each section now groups by cell (ordered by the
  cell's total), like the activity rows. Derived output only — footing is unchanged.
- **`:Daylog repeat` / cross-midnight carryover no longer taint a break.** Repeating a tagged entry
  immediately before a blank break re-emitted the break as `HH:MM #-`, tripping the plugin's own
  `blank_entry_metadata` diagnostic on the break line; the compensating tag/location clear now lands on
  the first real entry after the break (a utc offset may still ride the blank), so a break stays metadata-free.
- **`:Daylog balance`** rejects a non-decimal step argument (`0x2`, `1e1`) instead of silently balancing by
  the coerced number, matching the integer-step contract the help advertises.
- **Azure DevOps sync survives a deleted work item.** The hydrate request sets `errorPolicy=Omit`, so a
  work item deleted or made inaccessible between the query and the fetch drops from the batch instead of
  failing the whole sync with an HTTP 404.
- **An absolute Windows `core.hooksPath`** (e.g. `C:/hooks`) is detected as absolute when installing the
  commit-audit hook, instead of being joined onto the repository root.

## 0.18.0 - 2026-07-09

### Added

- **Export straight to a file.** `:Daylog export csv [range] <path>` (or `json`) now writes the export to
  `<path>` — creating parent directories and reporting how many rows it wrote — when the last argument
  looks like a path (contains a `/`, starts with `~`, or ends `.csv`/`.json`). Without a path it still
  opens the read-only preview buffer to yank or `:w` elsewhere. `require("daylog").export(format, range,
  path)` takes the optional `path` too.
- **Optional commit audit.** A `post-commit` hook (`contrib/daybook-post-commit.sample`) classifies each
  daybook commit by parsing its `.day` diff — `notes`, `today`, or `other-day` (the log changed for a day
  other than the commit day) — recording a git note per commit (`git log --notes=daylog`) and tagging the
  other-day commits `daylog-other-day/<date>-<hash>`. Only the active `--- log ---` block is compared, so
  notes/summary edits stay `notes`. Install it from Neovim with
  `require("daylog").install_commit_audit_hook()` (nothing to edit — the plugin path and your daybook.root
  are filled in). See docs/version-control.md.

### Changed

- **Export gained a `location` column** and now emits one row per `(day, activity, tag, location)`, so an
  activity split across `@location`s exports as one row per location (matching a timesheet); rows are
  sorted deterministically for stable diffs.
- **CSV export neutralizes spreadsheet formula prefixes.** A field beginning `=` `+` `-` or `@` is
  prefixed with a `'`, so a logged activity like `-2h round` cannot be executed as a formula on open
  (JSON is unaffected).

## 0.17.0 - 2026-07-09

### Added

- **Debounced autosave.** Set `autosave = <seconds>` in `setup()` to have a modified `.day` buffer write
  itself to disk that many seconds after your last edit (each new edit resets the timer). Disabled by
  default. It is a normal `:write`, so your `auto_summary` setting still governs the summary; only real
  daylog buffers are touched, never the read-only report/export scratch buffers.

- **`:Daylog log` works from a report.** `:Daylog log` / `:Daylog! log` on a row of a `:Daylog report`
  buffer now mark (or unlog) that item across the underlying day files — one file for a per-day row,
  every day of the period for an aggregate row — the same way `:Daylog rename` already fans out. Each
  day freezes its own committed value, a day lacking the item is skipped, the chosen name-set applies to
  all, and a confirmation lists the files first.

### Changed

- **The time bar places activity labels more cleverly.** Each label's colour swatch now sits *on* one of
  its activity's segments (rather than the whole label being centred over it), and the segment is chosen
  from *all* of the activity's occurrences to lay the row out best. When labels are crowded, a long label
  is shortened (with `…`) rather than a neighbour dropped, and free bar space reflows leftward so a
  constricted label can expand — a right label even slides to its own block's edge to make room. A label
  is dropped only when even its shortest still-distinct form cannot sit anywhere on its colour.

### Fixed

- **`:Daylog log` now freezes exactly the value the summary shows.** When some activities were already
  logged with rounded values below their honest total, the remaining un-logged row absorbed the leftover
  rounding on screen (e.g. displaying `1.00h`), but logging it committed a *different*, smaller value and
  stranded a spurious remainder row. Logging (and `:Daylog balance`) now read the same rounding the
  display renders, so the committed value always equals the displayed one and nothing is stranded.

- **Repeating from a summary row no longer brings in a hidden mapping.** `:Daylog repeat` on a main
  summary row (same day, or across days into today) now inserts the resolved label you actually see in
  the summary as a plain unmapped entry, instead of copying the source entry's `description => alias`
  pair. Repeating an entry line directly is unchanged — it still reproduces the mapping.

## 0.16.1 - 2026-07-08

### Fixed

- **Summary over-count on certain heavy-commitment logs.** When a logged commitment (an `!S`/`!T`/`!L`/
  `!W` value) was already met exactly by the honest rounding, it was not tracked, so another
  commitment's rounding adjustment could pull that cell below its committed value; the summary then
  billed the full committed value against the smaller cell, over-counting one section by a bucket. The
  feasibility check now guards every committed cell (not only over-committed ones), so a log whose
  commitments genuinely cannot all be honored falls back to honest quantization with the existing
  "commitments contradict" diagnostic instead of silently mis-footing. (Derived-output change for the
  affected logs.)
- **`:Daylog rename` left a superfluous tag/location on the following entry.** Renaming a lone entry's
  `#tag` (or `@location`) to match its surroundings correctly dropped that entry's now-inherited token,
  but the entry after it kept the explicit token it only carried to switch *back* -- renaming `b #old`
  to the ambient `#A` left the next line as `c #A` even though `c` now inherits `#A`. The rename now
  also re-emits the entry following an affected one, dropping a token that became redundant while
  keeping one that is still needed.

## 0.16.0 - 2026-07-07

### Changed

- **`:Daylog log` adds logging names independently instead of toggling off; unlog is `:Daylog! log`
  or `<leader>dL`.** Logging a name onto an already-logged summary/tag/location/workday row now ADDS
  it to the row's slice rather than removing the marker -- `boss` onto `!S[ado]` gives `!S[ado,boss]`
  (one slice reported to both, counted once), so an item can be reported to several places over time.
  Report to several at once with one multi-select (`!S[ado,timesheet]`). Unlog with `:Daylog! log`
  (bang) or the new `<leader>dL`: it removes names, opening a picker over the row's own names to
  choose which when it carries several, and clears the marker once its last name is gone.
- **The unnamed name is a first-class, additive member of a marker's name-set.** A bare `!S` (or
  `!S[]`) is the set `{unnamed}` — written with explicit empty brackets, `!S[]60` (was `!S60`), compact
  `!S[]60T[]120`, summary rows `#x !T[]` — so "logged to no one" is visible and distinct from an
  unlogged row. Because unnamed is just a name, `:Daylog log` ADDS it: logging unnamed onto an
  `!S[hey]` slice yields `!S[,hey]` (the set `{unnamed, hey}`), and a real name added to `!S[]` yields
  `!S[,hey]` too — never a silent no-op or a replacement. Existing bare `!S`/`!T` markers still parse
  and report identically, normalizing to the bracketed form on the next rewrite. (Derived-output
  change.)

### Fixed

- **Logging a tag/location/workday remainder with a new name no longer inflates the day total.**
  Marking the unlogged remainder of a cell (e.g. a `#tag`) with a name used to fold the cell's
  already-committed unnamed slice into the new commitment, silently over-reporting -- a 2-hour day
  could show as 3 hours with no diagnostic. It now commits only the remainder's own time.
- **Logging a tag/location/workday no longer marks the block's closing entry.** The last entry starts
  no interval; a marker on it was inert but would silently under-log once a later entry was appended
  beneath it.
- **Logging a new name on a tag/location/workday slice's drift row no longer marks a different entry.**
  When a committed named slice had grown past its frozen value it showed a "drift" row; pointing at
  that row and logging a new name silently committed an unrelated entry in the cell (footing stayed
  correct, so nothing warned). The section levels now refuse it -- "unlog the `!T` row to re-log it" --
  exactly as the summary level already did.
- **Merging a partially-committed cell no longer writes a short logged value.** Marking a cell's
  unlogged remainder to merge it into its logged slice summed the frozen row's committed value rather
  than its honest duration, so a row committed below its rounded duration (`!S[]45` on a 60m interval)
  merged to `!S[]105` and left a phantom remainder. It now commits the cell's full total.
- **`:Daylog report` / `:Daylog export` tolerate a trailing space in the range.** `:Daylog report 7 `
  (an easy stray space after completion) no longer fails with an "unparseable range" error.
- **A westward `utc` offset is capped at the real -12:00.** `utc-13` and `utc-14` used to parse (the
  magnitude was bounded symmetrically at 14h); only `-12:00`..`+14:00` is accepted now.
- **A pathological `round±N` digit run is rejected** instead of overflowing to a garbage/`inf`
  duration, mirroring the logged-marker value cap.
- **Daybook file discovery walks the configured path literally** (via `vim.fs.find`), so a `daybook`
  root containing `[`/`{`/`?` no longer misses files by interpreting them as a glob.

- **The time bar no longer errors on Neovim 0.8.** The strip's `eventignore` list is filtered to the
  events the running Neovim knows; `WinResized` is 0.9+, so feeding `eventignore` that unknown name
  threw `E474` on the 0.8 floor, crashing the bar render whenever a `.day` file was opened with the
  bar enabled.
- **A failed source-cache write no longer strands a temp file.** `write_cache` removes its `.tmp`
  scratch file when the atomic rename fails, instead of leaving it behind.

## 0.15.0 - 2026-07-06

### Changed

- **Logging is multi-level, and every section still foots.** An entry can be logged at the summary
  (`!S`), tag (`!T`), location (`!L`), or workday (`!W`) level independently. A logged section splits its
  cell into a reported slice (shown at the committed value) and
  a remaining slice, and a logged row renders with its level's marker (a logged tag row shows
  `... #ClientA !T`, a logged location `... @home !L`). All four sections are one shared quantization
  projected four ways, so they always foot to the same total: a commitment that reports more or less than
  the honest rounding is absorbed by the remaining slice (equal-and-opposite `(±Nm)` residuals), and an
  over-commitment beyond the cell's tracked time propagates to every section. Logging an activity's
  summary does not change what its tag or location reports — you log those separately. **The separate
  `--- logged ---` section is removed** (each section carries its own split now) — a derived-output
  change, so summaries with logged work render differently on upgrade; `:Daylog refresh` (or
  auto-summary) reclaims a stale `--- logged ---` section left by an older version. A hand-typed bare
  marker (`!S` with no value) now just flags the row logged rather than splitting it; only a committed
  value splits. `:Daylog balance` acts on an
  activity or the workday total, and its nudge now flows into the tag and location totals too (they foot
  to the balanced total); balancing directly on a tag or location row is refused.
- **BREAKING — `#ooo` and the out-of-office concept are removed; uncounted time is now a blank
  entry.** A blank entry — a bare `HH:MM` timestamp with no activity text — starts no interval, so its
  time is excluded from every report (a break or lunch). A blank carries no metadata: a tag, location,
  logging marker, `=> alias`, or `round±N` on a blank raises the `blank_entry_metadata` diagnostic
  ("a blank entry cannot carry a tag, location, marker, alias, or round nudge"); a `utc` offset is
  allowed (it records a clock change during the gap). A blank is not a `:Daylog map` or `:Daylog rename`
  target (both refuse it), and `:Daylog log` never marks one at any level (`!S`/`!T`/`!L`/`!W`), even
  though it inherits the sticky tag/location. In the time bar, a blank's dead period shows as a thin
  `┊` gap marker (highlight `DaylogBarGap`) instead of silently collapsing. `#ooo` is now an ordinary tag with no special meaning — an entry tagged
  `#ooo` is fully counted, logged like any other, and given no special highlight. There is no migration:
  an old file using `#ooo` treats it as a normal tag, so its time becomes counted. The four `#ooo`
  v0.1.0 compat fixtures are removed.
- **The `--- totals ---` section is a single `workday` total, loggable with `!W`.** It shows one
  `workday` row — the whole counted day, which foots to the activity total (uncounted time is a blank
  entry, which reaches no report), replacing the old `activity` / `workday` pair. It is still loggable
  with `!W`, splitting into a reported and a remaining row like `!S`. This is a derived-output change.
- **`:Daylog log` logs at the level of the row under the cursor.** On a main activity row it toggles
  `!S` (as before); on a `--- tags ---` row it toggles `!T` for that whole tag; on a `--- locations ---`
  row it toggles `!L` for that location; on the `--- totals ---` workday row it toggles `!W` for the
  whole workday — freezing the group at its displayed total and stamping the committed value on its
  entries, or clearing the marker to unlog.
- **Logged markers write as one compact token.** An entry's markers ride in a single token in
  `S T L W` order — `!S225T525W525` instead of `!S225 !T525 !W525` — for terser lines. The separated
  form (and any mix) still parses, so existing logs keep working; the writer normalizes to the compact
  token on the next rewrite.

- **BREAKING — the logged marker `!L` is now `!S`.** Logging is becoming multi-level: an entry can be
  logged at the summary (`!S`), tag (`!T`), location (`!L`), or workday (`!W`) level, each independently.
  The v0.1.x single summary-logged marker `!L` is now `!S`, and `!L` becomes the *location* level. **Run
  `:Daylog migrate` once on existing logs** to rewrite `!L`→`!S` before typing any new location marker
  (it can't be auto-detected — an old and a new `!L` are the same token). `!S` behaves as `!L` did, and
  `!T`/`!L`/`!W` add the tag, location, and workday levels described above. (v0.1.0 compat fixtures
  contain no `!L`, so the frozen baseline is unaffected.)

### Added

- **Named logging: mark a row for a specific report.** A logging marker can carry a bracketed
  name-set — `!T[jira,boss]` — naming who or what the slice was reported to, at any level (`!S[a]`,
  `!T[a,b]`, `!L[a]`, `!W[a]`). Names are a canonical sorted set (letters, digits, `_`, `-`), and the
  name-set is part of the row's identity: two differently-named slices of one cell report as separate
  rows and never merge, while a same-named slice merges and recommits at the combined total. When
  `:Daylog log` marks a row it opens a picker of the names you have used before at that level, ranked
  by the same daylog frecency as the insert picker, with a synthetic `(unnamed)` entry first (plain
  Enter marks with no name). With Telescope, typing filters, `<Tab>` multi-selects, and `<C-e>` (or
  `<CR>` when the filter matches nothing) creates the typed name — or a comma-separated list; without
  Telescope, a prompt takes a comma-separated list (empty for none). Unmarking never opens the picker.
- **The time bar shows a before/after view of mappings.** When the active log has mapped entries
  (`=> alias`), `:Daylog bar` stacks two column-aligned rows — the raw descriptions on top, the mapped
  report labels below — so you can see at a glance what a mapping consolidates. With no mappings the two
  rows would be identical, so a single bar renders. Each distinct activity is labelled once, placed over
  its widest segment (overlaps resolved by an optimal 1-D placement — isotonic regression / PAVA — and,
  when labels can't all fit, the least-present abbreviated then dropped). When mapped, each bar carries
  its own label row on its outer side (raw labels above the raw bar, resolved labels below the resolved
  bar) naming only its own activities; the hover tooltip reports the raw item on the top row and the
  mapped label on the bottom.

### Changed

- **`:Daylog map` skips a no-op self-mapping.** Mapping an entry onto its own description no longer
  writes a redundant `=> c` (a bare row and `c => c` report identically). A visual-range map onto one of
  the selected items — `a b c d e` → `c` — now leaves `c` untouched; mapping an already-aliased entry
  onto its own description clears the alias instead.

### Added

- **Broken logs are flagged in red.** When a log carries a logging error — same-activity `!S` values
  that disagree, or a frozen value that no longer fits the
  bucket — or a structural error (an out-of-order or invalid entry), the offending line **and** its
  now-untrustworthy summary are highlighted red until the error is fixed, then clear on their own. The
  colour is the `DaylogError` group, restylable via `:highlight`.

### Fixed

- **`:Daylog copy` and `:Daylog new` emit the canonical two-blank separator**, so the next refresh no
  longer rewrites the seam (an extra undo block on every copy/new). The `copy_active_block` compat
  fixture is updated deliberately for this derived-output change.
- **Re-running `setup()` replaces buffer-local keymaps instead of stacking them**, and turning keymaps
  off removes them from open daylog buffers.
- **Diagnostics publish on file open** (the settle pass already computed them and threw them away), and
  they publish to the buffer they belong to rather than whichever buffer is current.
- **Balancing the frozen (`!W`) totals slice is refused** like any logged row, instead of silently
  nudging the unlogged slice while the cursor stays parked on the frozen one.
- **The below-zero `round±N` warning judges the displayed summary**, so it no longer fires against a
  row that renders fine inside a committed cell.
- **Logging the drift remainder of a fully-committed cell names the real remedy** ("unlog the `!S` row
  to re-log it") instead of suggesting a summary regeneration that reproduces the same row.
- **Unmarking a tag/location/workday row also clears a marker stranded on a blanked entry**, so the
  toggle actually clears the level.
- **`:checkhealth daylog` reports the real verb list** (derived from the command table; it had drifted
  and fabricated per-verb checks), the stray-cursor mark reads the cursor of the window actually
  showing the buffer, and `:Daylog now`'s drifted-timezone insert is covered above.
- **Splitting a mapped group keeps the mapping.** `:Daylog split` on an aliased row now suffixes the
  resolved label (`meeting => MTG-1 (1)`), so descriptions survive, parts group across the whole mapped
  group, and a bare and a mapped group split identically. Previously the alias was dropped and each
  entry's description was suffixed, fragmenting the split across rows.
- **A ranged `:Daylog map`/`rename` skips a blank entry instead of refusing the whole selection.** A
  visual range spanning a lunch break now maps/renames its entries; the single-cursor refusal on a
  blank stays.
- **A pasted title can no longer inject or corrupt a mapping.** `:Daylog insert` sanitization now
  neutralizes every `=>` token (consecutive arrows and a leading arrow included), so an external
  work-item title cannot silently become an alias, and an alias round-trips the formatter unchanged.
- **Prose like `--- meeting summary ---` no longer fragments a log.** A section word in second position
  is a structural header only after a report prefix (`day`/`range`); other `--- x ---` lines stay
  notes, so entries after such prose no longer silently vanish from the summary.
- **The work-item picker no longer crashes on a `null` field.** JSON nulls from the tracker (state,
  changed-date, url) are filtered at the decode boundary and the ranker ignores non-string recency
  values, instead of erroring inside the sort (and poisoning the cache until the next sync).
- **`:Daylog now` with a drifted timezone no longer corrupts the entry.** Typing after the insert lands
  in the gap before the recorded `utc±N` token (`11:00 meeting utc+1`); the shell previously jumped to
  end-of-line, producing an unparseable `utc+1meeting`.
- **Logging a manually-rounded row no longer changes an unrelated row, and `:Daylog log` is now
  order-independent.** When an entry carried a `round±N` nudge and was then logged (`:Daylog log` /
  `!S`), the frozen row's residual used to be forced onto another activity's duration (and the day
  total) to keep an abstract whole-day rounded total; logging a second row could then even commit it at
  the wrong value depending on which row was logged first. Frozen rows are now held at their committed
  value and the remaining rows round to *their own* total (`quantize.frozen_aware_target`, used by both
  the display and the committed-value path), so the day total is the honest sum of the displayed parts
  and each `!S` value is the row's displayed duration regardless of logging order. Logging now obeys the
  same rounding a `round±N` nudge already does — summaries combining `!S` with a nudge render
  consistently with the un-logged case, so their derived output changes on upgrade.
- **`:Daylog log` gives a clear message when the cursor isn't on a summary row.** Running it on an
  entry line, a totals/tag row, or a blank used to report "summary row does not match the active log;
  regenerate the summary" — misleading, since nothing was stale. It now says to put the cursor on an
  activity's summary row; a genuinely out-of-date summary still asks you to regenerate.

### Added

- **`:Daylog export csv|json [range]` writes a machine-readable summary.** Export a day or a range
  (the `report` date vocabulary, defaulting to today) as CSV or JSON into a scratch buffer you save or
  yank -- one row per activity per day (`date, activity, tag, minutes, hours, logged`), carrying
  the same quantized numbers `:Daylog report` shows, ready for a timesheet / invoicing tool / script.
  `require("daylog").export(format, range)` returns the string for scripting.

## 0.14.0 - 2026-06-30

### Added

- **A color-coded time bar (`:Daylog bar`).** An opt-in horizontal bar at the bottom of the daylog
  window shows where the day went: each segment is an interval, its width proportional to the real
  time spent and its colour the activity (resolved label), with a legend. It lives in a reserved
  split at the bottom of the daylog window (always visible, never overlapping content) and, on
  today's log with a future-dated final entry, marks where the current time falls. Toggle it globally
  with `:Daylog bar` or `<leader>db`, or show it by default with `time_bar = true`. The `DaylogBar{n}`
  groups are overridable.
- **A mouse-hover tooltip on the time bar (`time_bar_hover`).** With `time_bar_hover = true` (and
  Neovim's `mousemoveevent` set), hovering the bar shows the clock time at the pointer and the activity
  there. Opt-in and off by default; daylog never enables `mousemoveevent` for you.
- **`:Daylog keys` shows a keymap cheatsheet.** A popup (also `g?` in `.day` files when
  `keymaps = true`) lists the daylog keymaps active in the buffer, plus how to open today and reach
  the full command set. The `keymaps = true` default set now also carries per-key descriptions, so
  which-key renders a labelled menu instead of an unlabelled blob.
- **`:[range]Daylog rename` renames a selection of entries.** Over a visual range (or `:N,M`), every
  selected entry line is set to one new description -- the ranged counterpart of the per-entry
  rename, mirroring ranged `:Daylog map` (summary / structural lines in the range are skipped).

### Changed

- **Activity colours are generated in OkLCH instead of a fixed palette.** The old 8-colour palette
  repeated -- and even aliased different activities to one terminal colour -- once a log had more than
  8 activities. It is replaced by a generator that picks each activity's colour by farthest-point
  sampling in OkLCH (a perceptually-uniform space), keeping them as distinct as possible across hue,
  lightness, and saturation, with no practical limit. The per-activity `DaylogBar{n}` /
  `DaylogSign{n}` groups (and the colours they cover) are still overridable with your own `:highlight`.
- **The time bar legend abbreviates instead of dropping labels.** When the legend is wider than the
  window, the longest labels are shortened to a still-distinct prefix (with a trailing `…`, floored at
  three characters) before any are dropped; only once even those minimums do not fit are the
  least-fitting labels evicted from the end. The hover tooltip (`time_bar_hover`) still shows the full
  activity name.
- **The active-log indicator is now per-activity colored.** The uniform green margin bar is replaced
  by a colour per activity: each entry and the notes beneath it carry the activity's colour, and each
  summary row carries its activity's colour -- so an activity reads as one connected colour down the
  margin and across to its summary line, matching the time bar. Colours are assigned by order of
  first appearance (so they stay stable as the day grows, never reshuffling by duration) and come
  from the `DaylogSign{n}` groups (the `DaylogActiveSign` group is gone).
- **`:Daylog` registers at plugin load.** The command is available the moment daylog is installed --
  any plugin manager, no `setup()` call -- so `setup()` is now purely optional configuration (the
  daybook, sources, keymaps). `:Daylog today` warns until you set `daybook.root`, while the editing
  verbs and highlighting work on any `.day` file with no config. The dispatch lazy-loads the
  implementation, so registering at startup stays cheap.
- **`:Daylog map` over a visual range now also collapses summary rows.** A visual selection
  (or an explicit `:N,M` range) that covers main summary rows maps every entry feeding those
  rows, so selecting a span of summary rows folds those activities under one label -- the same
  gesture that already worked over a range of entry lines. Structural lines (headers, blanks,
  totals) in the selection are ignored.
- **The `keymaps = true` cluster moved to the `<leader>d` namespace and gained map / rename
  (breaking).** Its editing verbs were under `<localleader>` (which is `\` until you set
  `maplocalleader`); they now sit under `<leader>d` (gitsigns-style), so the set rides whatever
  `<leader>` you have and shadows a global `<leader>d*` only inside `.day` files. The cluster now
  also binds `dm` map and `dR` rename (both normal and visual mode); `dR` is rename (it was refresh,
  which moved to `df`). `]d` / `[d` and `g?` are unchanged.

### Removed

- **The `<Plug>(daylog-*)` mappings (breaking).** They were a redundant third interface beside the
  `:Daylog <verb>` command and the `require("daylog").<verb>()` Lua API, and -- being fixed actions
  -- could not carry a count or an argument. Bind the command (`<Cmd>Daylog today<CR>`) or the
  function (`require("daylog").today()`) to your keys instead. `]d` / `[d` in the opt-in set are now
  count-aware, and a custom `keymaps = { lhs = rhs }` table now accepts a Lua function as well as a
  mapping string.

## 0.13.0 - 2026-06-28

### Added

- **`:Daylog new` scaffolds a fresh log into the current buffer.** It writes a new `--- log ---`
  header (from your configured `defaults`) in place when the buffer is empty, or appends it as a
  new active log after existing content, with the cursor on the new header. It writes only the
  header -- no entries, no summary -- so starting a new daylog no longer needs a copy/pasted
  header or a `:Daylog copy`-then-delete; begin logging with `:Daylog insert`.

### Changed

- **All commands are now one `:Daylog <verb>` command (breaking).** The 17 `:Daylog*` commands
  are replaced by a single `:Daylog` with verb completion: `:DaylogToday` -> `:Daylog` /
  `:Daylog today`, `:DaylogInsert` -> `:Daylog insert`, `:DaylogDays` -> `:Daylog report`,
  `:DaylogNextDay` / `:DaylogPrevDay` -> `:Daylog next` / `:Daylog prev`, and so on; `:DaylogInit`
  and `:DaylogToday`'s offset both fold into `:Daylog day <when>`. A bang selects a verb's
  variant (`:Daylog! insert` / `map` / `report`) and a bare `:Daylog` opens today. Update your
  config and any mappings.
- **One date vocabulary everywhere.** `:Daylog day` and `:Daylog report` bounds share the same
  tokens -- `today` / `yesterday` / `tomorrow`, weekday names, signed `+N` / `-N` offsets, and
  `YYYY-MM-DD` -- so `:Daylog day monday` and `:Daylog report -7..today` both work.
- **`:Daylog day` creates the target day.** Where `:DaylogToday <offset>` *navigated* to a day
  without creating it, `:Daylog day <when>` opens or **creates and scaffolds** it (the old
  `:DaylogInit` behaviour), and takes a *signed* offset -- `:Daylog day +1` / `-3`, not a bare
  `1` (a bare number is a `:Daylog report` day count). Move between existing logged days with
  `:Daylog next` / `:Daylog prev`.
- **A Lua API and `<Plug>` mappings.** Every verb is a `require("daylog").<verb>()` function and
  a `<Plug>(daylog-*)` mapping; `setup({ keymaps = true })` applies an opt-in, buffer-local
  default key set (`]d` / `[d` plus a `<localleader>` cluster), or pass a `{ lhs = rhs }` table.

### Fixed

- **`:Daylog balance` no longer over-rounds an entry below zero.** Running a round-down on an
  entry directly (cursor on the `HH:MM` line) ignored the floor the summary-row path already
  enforces, so e.g. `:Daylog balance -50` on a one-hour activity wrote a bogus `round-50`
  marker and rendered the row as `0.00h (+60m)`. The entry path now refuses with the same
  "cannot round down further" message once a step would take the displayed duration below
  zero, matching `:Daylog balance` on a summary row.
- **An out-of-range `round±N` marker now raises a diagnostic.** A `round-N` typed by hand (or
  left stale by an edit that shrank the activity) large enough to round an item below zero was
  honored silently — the row rendered `0.00h` with the marker intact. Refresh now flags it
  (`daylog: round-N rounds this item below zero; clear or reduce the nudge`) at the offending
  entry so the undefined marker is surfaced and corrected; the summary still renders the
  clamped row.
- **`:Daylog split` gives a clearer error off an activity row.** With the cursor on an entry or
  a totals row it reported the misleading "summary row does not match the active log;
  regenerate the summary"; it now says to put the cursor on an activity summary row, reserving
  the regenerate message for a genuine summary/log mismatch.
- **The source cache now refreshes on native Windows.** Cache writes renamed the temp file
  with `os.rename`, which cannot overwrite an existing file on Windows, so every sync after
  the first failed and the picker kept reading the stale cache. Writes now use
  `vim.loop.fs_rename`, which replaces atomically on every platform.
- **Frecency ranking now credits mapped entries to the item they map to.** The picker's
  recent-activity ranking keyed on an entry's description, so a `=> alias` mapping never
  boosted the source item it reported as and also surfaced a duplicate "activity" row. It now
  keys on the resolved label (alias when set), so a bare and a mapped entry rank as one.
- **`auto_summary = "change"` no longer races across daylog buffers.** The 200ms debounce used
  one counter shared by every daylog buffer, so editing a second daylog within the window
  cancelled the first's pending refresh, and the deferred refresh did not re-check its buffer,
  so switching buffers could refresh the wrong one. The debounce is now per buffer and the
  deferred refresh only fires when its buffer is still current.
- **A non-flat Azure DevOps query now reports an error instead of an empty picker.** A saved
  query configured as a tree or work-items-and-direct-links query returns `workItemRelations`
  rather than `workItems`, which silently produced no items; it now surfaces a clear error
  asking for a flat work-item query.
- **A note shaped like an unsigned `(Nm)` is no longer mistaken for a summary row.** The
  generated-row predicate accepted an optional sign, so a hand-written note like `lunch (5m)
  break` sitting just above the summary could be swept as generated debris on a refresh.
  Generated rows always sign the marker, so the sign is now required.
- **`:Daylog order` rebuilds each reordered log's summary.** Reordering changes the intervals,
  and so the durations, so `:Daylog order` now regenerates each affected log's existing summary
  from the sorted entries in the same edit — instant and independent of `auto_summary`, like
  the other editing commands — instead of leaving it stale for a later refresh. A log with no
  summary is left untouched. (The `order_notes_and_clears` v0.1.0 compat fixture's derived
  output is updated to match.)

## 0.12.0 - 2026-06-25

### Added

- **`:DaylogMap` accepts a range — map a whole selection at once.** Visually select a block of
  entries (then `:`, which fills in the range) or give an explicit `:N,MDaylogMap` to set or clear
  the `=> alias` on every entry in the selection in one step — handy now that mapping is the way to
  relabel for the report. Non-entry lines (header, blanks, the summary) are ignored and it is scoped
  to the active log; a logged (`!L`) entry in the selection refuses the whole map (exclude or unlog
  it). A bare `:DaylogMap` on the cursor entry/row is unchanged. Bind a visual-mode keymap with the
  `:` form (`vim.keymap.set("x", "<leader>dm", ":DaylogMap<cr>")`), not `<cmd>`.

- **`auto_timezone` (default on): automatic UTC-offset tracking.** A new day's header now carries
  the system UTC offset as a baseline (e.g. `--- log utc+2 ---`), and every current-time insert
  (`:DaylogInsert`, `:DaylogRepeat`, and the past-midnight / cross-day variants) records a `utc±N`
  token when the live offset has drifted — a DST switch or travel — with a one-line notice. So an
  interval that spans the change keeps its true length instead of silently gaining or losing the
  hour. The check only adds a token when the day already has an offset baseline, and is a no-op on
  platforms that report no numeric offset. An explicit `defaults.utc` still wins the header. Set
  `auto_timezone = false` to record offsets only when you type them. **Behavior change:** new day
  headers now carry a UTC offset by default. See `:help daylog-auto-timezone`.

- **Diagnostic: a log must be all-or-nothing on UTC offsets.** Introducing a `utc±N` token after
  offset-free entries is now refused (a block diagnostic, like out-of-order timestamps), because it
  would silently reinterpret the entries before it — the transition interval jumps by the offset.
  Make the log consistent by putting the offset on the header (or removing it); `utc+0` on the
  header pins a real-time log to UTC explicitly. A fully naive or fully timezoned log is unaffected.

### Changed

- **Picker ranking is now standard Mozilla-style frecency.** The worklog ranker that orders a
  source's cached items (and the `:DaylogInsert!` pool) previously folded each activity's tracked
  *duration* into a time-decayed score. It now uses the standard Firefox frecency formula: each
  logged entry is a "visit", and an activity scores its total visit count times the average
  recency weight (100 / 70 / 50 / 30 / 10 by 4 / 14 / 31 / 90 days) of its most recent visits —
  recency and frequency only, no duration. The daybook scan window (`picker.frecency_days`) and
  the wholesale `picker.rank` override are unchanged; a custom `rank` now receives `usage` entries
  shaped `{ count, latest, score }`.

- **`:DaylogRename` no longer renames an activity from its summary row.** A summary row groups
  entries that resolve to one label by different means (a bare entry's description, or a mapped
  entry's `=> alias`), so a bulk rename through it was ambiguous and could silently overwrite the
  distinct descriptions a mapping deliberately keeps. Rename now acts only on a **single entry's
  text** or a **`#tag`/`@location`** (from the cursor or a `:DaylogDays` report); use `:DaylogMap`
  to relabel or merge an activity for the report (non-destructive — your journal text stays).
  Renaming an *activity* across days from a report is dropped too; tags and locations still rename
  across days.

### Removed

- **`picker.half_life_days` and `picker.base`** — the tuning knobs for the old duration-aware
  decay have no meaning under Mozilla frecency. They are silently ignored if set (not an error).

### Fixed

- **`:DaylogMap` on a summary row also affects the log's closing entry** when it shares the row's
  activity. The final entry starts no interval (so it has no duration in the summary), but it is
  the same activity and will start contributing the moment another entry follows it — so its alias
  now stays in step with the rest of the row. `:DaylogLog` is unchanged: it freezes a duration, and
  the closing entry has none to freeze.

## 0.11.0 - 2026-06-25

### Added

- **`:DaylogInsert!` — the unified "what to log" picker.** One fuzzy, offline list that pools
  every configured source's cached work items together with your recent logged activities
  (across days), ranked by worklog frecency and de-duplicated so an activity matching a tracked
  item appears once. Pick a row to insert it, type a fresh activity, or cancel for a bare
  timestamp. Bare `:DaylogInsert` (stamp the time) and `:DaylogInsert <source>` are unchanged.
- **Entry mapping (`=> alias`) and `:DaylogMap`.** An entry can carry `=> label`
  after its description: it keeps what you wrote but resolves to `label` in the
  summary — counting toward, and shown as, that target — so several entries (even
  with different descriptions) that share an alias fold into one row. The trailing
  metadata (`#tag`, `!L`, ...) follows the alias and attaches to the entry as usual.
  `:DaylogMap {label}` sets the alias on the entry under the cursor, or on every
  entry of a main summary row; with a configured source it can map onto a work item
  via a picker. `:DaylogMap!` clears it. A logged (`!L`) entry is refused. This is a
  non-destructive alternative to renaming or copy-and-clean: the day file stays your
  own journal while the summary reads canonically. `:DaylogRename` still edits the
  description; mapping sets the report label.

- **`:DaylogDays` takes a flexible date range with named dates.** Besides the trailing
  count (`:DaylogDays 5`), it takes a `FROM..TO` range and the open-ended forms `FROM..`,
  `..TO`, and `..`. Each bound is a `YYYY-MM-DD` date or a named token — `today`,
  `yesterday`, or a weekday (`monday`..`sunday` / `mon`..`sun`), which resolves to its most
  recent occurrence on or before today. Open ends reach the data's extent on both sides
  (the earliest/latest day on file), future-dated files included — so a week is
  `:DaylogDays monday..`, or `monday..today` to stop at today. Days are taken by calendar
  date; missing days are skipped, and a reversed/unparseable range or an empty span is
  reported. The aggregate headers show the resolved span and a `(N found)` count, e.g.
  `--- range summary 2026-05-12..2026-05-18 (3 found) ---`.

### Changed

- **One picker for Insert!, Rename, and Map; the rendered name leads.** `:DaylogRename` and
  `:DaylogMap` now open the same unified pool as `:DaylogInsert!` — your recent activities plus
  every source's work items, frecency-ranked and de-duplicated — instead of a single source's
  items; pick a row to rename/map onto it. Naming a source still scopes the picker to that one
  tracker, with live search (`search = true`) — exactly like `:DaylogInsert <source>` — and
  renaming a tag/location still offers the other tags/locations. Tracked items now display with
  their inserted text (`{id} {title}`) on the far left, lined up with the plain activity rows, and
  the `[type/state]`/project metadata trailing — dimmed in the Telescope picker via the overridable
  `DaylogPickerMeta` highlight group so the name stands out.
- **Source pickers lead with what you've been working on.** A source's cached work items
  are now ordered by your worklog — a time-decayed frecency that weighs how recently, how
  often, and how much *time* you've logged against each item, so the things you actually work
  on rise to the top. Tunable via `picker.frecency_days` / `half_life_days` / `base`, or
  replace the ordering entirely with `picker.rank`. Works for any source.
- **Live tracker search is now opt-in** — set `search = true` on a source to enable the
  per-keystroke network search. By default the picker reads the offline cache and filters
  locally (instant, no network); with Telescope you still get a fuzzy picker over the cache.
- **Azure DevOps default scope is now organization-wide and person-scoped.** The cache (and
  live search) lists work items that **involve you** — assigned to *or* created by you — that
  are active and recently changed, **organization-wide** by default. `project`/`projects` are
  now optional (set one to narrow); search carries the same scope. Use `query`/`query_id` for
  a custom scope (`query_id` needs a `project`).

### Removed

- **`:DaylogWeek`** (breaking) — a week is now `:DaylogDays monday..` (or `monday..today`).
  The report shows the resolved span and `(N found)` rather than the ISO-week label.

### Fixed

- **`:DaylogSplit` across a UTC offset change.** Split now apportions an activity's
  *effective* (real-world) time rather than its raw local span, so an interval that
  crosses an offset change is divided by the real elapsed time the summary shows. The
  cuts are placed at the interval's own offset with no new `utc` token, and the result
  stays in real-time order even when a later entry, written in a new time zone, reads
  earlier on the wall clock — so a log like `10:00 A` / `09:00 B utc-2` now splits
  correctly instead of erroring. The only refusal is the rare case where a
  westward jump would push a cut to or past 24:00, which can't be written without a new
  offset.

- **`:DaylogRename` renames a single entry** when the cursor is on an entry line.
- **`:DaylogRename` still opens the merge picker** when a configured source is unreachable.
- **`:DaylogBalance` keeps the cursor on a summary row** that reorders.
- **`:DaylogCopy` moves the cursor onto the new copy** so it is visible.

## 0.10.0 - 2026-06-24

### Added

- **`:DaylogSplit` command**. Split the activity on the summary row under the cursor into
  several sub-activities — `foo (1)`, `foo (2)`, … — dividing its time by an optional
  (unnormalized) weight vector whose length sets the number of parts (no args = even
  two-way split). Each interval is cut into consecutive sub-intervals (the starting entry
  renamed, the rest inserted, all inheriting the original's tag/location/utc offset), and
  the total time is preserved exactly. An interval too short to give every part a whole
  minute splits into fewer parts, with the shortfall compensated across the activity's
  longer intervals so each sub-activity's total tracks its weighted share. Logged
  activities cannot be split.
- **Frozen logged values (`!L<minutes>`)**. `:DaylogLog` now records the committed
  duration on the marked entry as `!L<minutes>` (e.g. `!L60`), and the quantizer holds
  that row at exactly that value while excluding it from the largest-remainder pool.
  Previously, appending a later entry could shift an already-logged row's rounded
  duration (e.g. a logged `1.00h` silently becoming `1.25h`), disagreeing with what was
  reported externally; a frozen row now never moves, the displayed total stays the
  honest rounded total, and the remaining rounding is shared only among un-frozen rows.
  Bare `!L` (logged but unfrozen) stays valid and unchanged. New on-disk token form;
  the summary still renders a bare `!L` (no number). `:DaylogRefresh` warns when a
  frozen value no longer reconciles with its log (a changed `q=`, an edit inside the
  logged interval, or deleted activity) so you can re-run `:DaylogLog` to recommit.
  `:DaylogBalance` now skips frozen logged rows when choosing where to apply a step
  (a committed value is never nudged), and errors when the only remaining candidates
  are logged — whether a round-down zeroed every other row or the scope is all logged.
  When one activity has several logged intervals they share a single committed value;
  if a hand edit leaves them disagreeing, `:DaylogRefresh` now warns (previously the
  fold silently kept only the first value) so you can re-run `:DaylogLog` to recommit.
  Logging an activity that already has a logged portion now merges the two and commits
  their summed time onto every contributing entry (previously the newly logged part
  kept its own value and the merged row collapsed to a single interval's duration).
- **Active-log awareness markers** (`active_indicator`, on by default). A soft-green
  sign-column bar marks the active log (the block the commands act on) on any clean
  daylog; on a file with two or more logs, a soft-red bar also follows the cursor when
  it strays into an earlier, non-active log. Both hide whenever the daylog has a
  diagnostic, so they never compete with a warning. Recolor via the `DaylogActiveSign`
  / `DaylogStraySign` highlight groups.

### Changed

- **Renamed the plugin to Daylog** (breaking). A timestamped entry is now an
  *entry* (was a *blot*); a `--- log ... ---` block is now a *log* (was a
  *blotter*); a day's file is a *daylog*. Files use the `.day` extension (was
  `.blot`) with `--- log ... ---` block headers (was `--- blots ... ---`), and the
  filetype is `daylog` (was `blotter`). All commands are unified under one
  `:Daylog` prefix — `:DaylogToday`, `:DaylogInit`, `:DaylogNextDay`,
  `:DaylogPrevDay`, `:DaylogWeek`, `:DaylogDays`, `:DaylogInsert`, `:DaylogRepeat`,
  `:DaylogRename`, `:DaylogLog`, `:DaylogBalance`, `:DaylogCopy`, `:DaylogOrder`,
  `:DaylogRefresh`, `:DaylogSync` (was the split `:Blot*` / `:Blotter*` prefixes).
  The Lua module is `require("daylog")`, health is `:checkhealth daylog`, help is
  `:help daylog.nvim`, highlight groups use the `Daylog*` prefix (was `Blotter*`),
  and messages are prefixed `daylog:`. Update your config: change
  `require("blotter").setup(...)` to `require("daylog").setup(...)`, rename the
  `journal` option to `daybook` (see below), and remap any `:Blot*` / `:Blotter*`
  keymaps to `:Daylog*`.
- **Config: `journal` → `daybook`** (breaking). The dated tree of day files is now
  your *daybook* (daybook ⊃ daylogs ⊃ logs ⊃ entries). Rename the config key:
  `setup({ journal = { … } })` → `setup({ daybook = { … } })`.
- **Clean break for existing files** (breaking). The new version reads only the new
  vocabulary; legacy `.blot` / `.wkl` files and their `--- blots ---` / `--- worklog ---`
  headers are no longer parsed. Convert an existing daybook once with
  `scripts/migrate-to-daylog.sh` (dry-run by default, `--apply` to perform it): it
  migrates `*.wkl` (worklog) or `*.blot` (blotter) straight to `*.day`, rewriting each
  block header to `--- log ... ---` (pick the source with `--from=wkl|blot`, or it
  auto-detects / asks). Per-source caches re-sync on first use (the cache moved from
  `…/blotter/` to `…/daylog/`).
- The `v0.1.0` compatibility fixtures were migrated to the new keyword and
  extension; they continue to guard summary-derivation stability.

## 0.9.0 - 2026-06-21

### Changed

- A blotter's generated summary is now separated from its body by **two** blank
  lines (previously one), and a summary refresh **regenerates the entire summary
  zone** — from the summary banner (`--- summary q=N d=fmt ---`) down to the next
  blotter or end of file — discarding anything found inside it (mid-summary prose,
  stranded or duplicated generated rows, trailing junk). The summary is derived,
  edit-free output, so put annotations on blots, never in the summary. A trailing
  note written below the summary is now regenerated away rather than preserved.
  This changes derived output: existing one-blank-separated summaries are rewritten
  to the two-blank layout on the next refresh; valid `.blot` bodies and their blots
  are untouched.
- Stacked blotters are also separated by **two** blank lines: a refresh now keeps the
  two-blank gap between one blotter's summary and the next blotter's header (trimmed
  to none at end of file), instead of collapsing it.

### Fixed

- A corrupted or missing blotter header no longer costs you the blotter. Previously, if a
  later blotter's `--- blots ---` header was damaged so it no longer parsed — a mistyped
  keyword (`--- blts …`), a dropped dash (`-- blots …`), an obliterated or deleted line —
  the preceding blotter's summary refresh ran straight through it and **wiped that blotter,
  its blots included**. Now a summary's regeneration can never cross into another blotter's
  blots, and the damaged header is **reconstructed**: its surviving parameters (`q=`, `d=`,
  `#tag`, `@location`, `utc±H`) are read back when present, otherwise a header is
  synthesized from the previous blotter's metadata — so the blotter is recognized and
  summarized again. (Any timestamped run below a summary is treated as a blotter, even
  under an unrelated `--- … ---` line, which carries no meaning of its own.)

## 0.8.0 - 2026-06-20

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
  tag/location/logged total that group); with the cursor on a blot that blot is
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
