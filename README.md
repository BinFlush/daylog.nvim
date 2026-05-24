# worklog.nvim

A focused Neovim plugin for structured plain-text worklogs.

`worklog.nvim` helps you keep a plain-text log of what you did during the day,
then derive clean summaries for reporting.

It is useful when time tracking needs more structure than a simple list of
timestamps: repeated work items, reporting tags, work locations,
out-of-office time, exact totals, and rounded reporting totals.

## Basic example

Write timestamped entries as the day happens:

```text
--- worklog ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```

Running `:WorklogQuantSum` adds a rounded summary:

```text
--- summary quantized ---
1.75h (+2m) planning
1.50h (+2m) PR review
0.50h (+3m) bugfixes on backend

--- totals quantized ---
3.75h (+7m) workday
```

Identical work items are automatically summed. Quantized summaries round to
15-minute buckets by default.

## Structured worklogs

You can add reporting tags, locations, and a custom quantization bucket:

```text
--- worklog #ClientA @office quantize=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

`#tag` and `@location` are sticky. When an entry omits one of them, it inherits
the current value:

```text
08:00-10:00 planning          #ClientA   @office
10:00-13:00 implementation    #ClientA   @home
13:00-14:00 internal meeting  #internal  @home
14:00-17:00 client followup   #ClientA   @client
```

Useful syntax:

```text
#ClientA       reporting tag
@office        work location
#ooo           out of office; counts as activity, not workday
!L             interval starting here was logged externally
#-             clear current tag
@-             clear current location
quantize=30    round summaries to 30-minute buckets
duration=hhmm  render summary durations as hours:minutes
```

`!L` is source syntax on timestamped entries. It is currently preserved by
source rewrites such as copy and order. Summaries and reports split main rows by
logged state, render logged rows with trailing `!L`, and add a logged section
for workday-eligible logged versus unlogged totals when logged work was marked.
Tag and location totals stay grouped normally.

`:WorklogLog` toggles the logged state of the main summary row under the cursor
by recomputing the active worklog summary and adding or removing a trailing `!L`
on the contributing source entries: an unlogged row becomes logged, and a logged
row becomes unlogged, then the worklog's single summary is rebuilt. It works
whether that summary is exact or quantized. It refuses `#ooo` rows, which cannot
be logged, and summary rows that no longer match the recomputed summary.

## Commands

| Command | Effect |
| --- | --- |
| `:WorklogNew` | Create a new worklog block using configured defaults |
| `:WorklogToday [offset]` | Open a journal file relative to today; nonzero offsets initialize missing or empty files without inserting the current time |
| `:WorklogNextDay [count]` | Step forward `count` days (default 1) relative to the open journal file, falling back to today |
| `:WorklogPrevDay [count]` | Step backward `count` days (default 1) relative to the open journal file, falling back to today |
| `:WorklogDays[!] {count}` | Open the last N journal days report; `!` shows only the aggregate range summary |
| `:WorklogWeek[!]` | Open this week's journal report; `!` shows only the aggregate weekly summary |
| `:WorklogInsert` | Insert current time in order and enter insert mode |
| `:WorklogRepeat` | Repeat the activity under the cursor at the current time |
| `:WorklogCheck` | Validate the current buffer without modifying it |
| `:WorklogCopy` | Append a normalized editable copy |
| `:WorklogOrder` | Rewrite worklog blocks in chronological order |
| `:WorklogSummarize` | Set the worklog's summary to an exact summary (replacing any existing one) |
| `:WorklogQuantSum` | Set the worklog's summary to a rounded summary (replacing any existing one) |
| `:WorklogLog` | Toggle the logged state of the main summary row under the cursor (add or remove `!L` on the contributing source entries) |
| `:WorklogRefresh` | Rebuild every existing summary in the buffer to match its entries |

The active worklog is the latest `--- worklog ... ---` block in the file.

## Live summaries

`:WorklogRefresh` rebuilds every summary already present in the buffer so it
matches its worklog's entries. Unlike `:WorklogSummarize` / `:WorklogQuantSum`
(which act on the active worklog), refresh updates **every** worklog that has a
summary, in its existing kind. It never creates or removes a summary — you opt a
worklog in by summarizing it once — and it leaves a worklog alone while it is
mid-edit and invalid.

To run it automatically, set `auto_summary` in `setup()`:

| `auto_summary` | When summaries refresh |
| --- | --- |
| `"off"` (default) | Never automatically; use `:WorklogRefresh` |
| `"change"` | Shortly after edits settle (debounced) |
| `"idle"` | When you pause or leave insert mode |
| `"save"` | On write (`:w`) |

```lua
require("worklog").setup({ auto_summary = "idle" })
```

## Limitations and syntax gotchas

- The final timestamp closes the previous interval and has no duration of its own.
- Entries use `HH:MM`; ranges, dates, and seconds are not supported.
- Keep times ordered before summarizing; use `:WorklogOrder` to rewrite blocks.
- `#tag` and `@location` are sticky until replaced or cleared with `#-` and `@-`.
- Only trailing metadata tokens are parsed as metadata; multiple trailing tags or locations are invalid.
- `#ooo` counts as activity but is excluded from workday totals.
- Main summary rows do not split by location; locations are reported separately.
- Each worklog has at most one summary (exact or quantized); re-running `:WorklogSummarize` or `:WorklogQuantSum` replaces it. The summary is regenerable derived output and owns the tail of its worklog — keep notes on entries, not in the summary.
- The active worklog is the latest worklog block in the file.

## Requirements

- Neovim 0.8.0 or newer

## Install

Example with `lazy.nvim`:

```lua
return {
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hhmm",
      },
      journal = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
      auto_summary = "idle",
    })
  end,
}
```

Every option is optional. The default fields are `tag`, `location`,
`quantize_minutes`, and `duration_format`. `auto_summary` (`"off"` by default,
or `"change"` / `"idle"` / `"save"`) controls when summaries refresh
automatically — see [Live summaries](#live-summaries).

Journal settings are optional too:

- `journal.root` is the base directory used by `:WorklogToday`.
- `journal.directory` is an optional `strftime` template under that root.
- The journal filename is always `YYYY-MM-DD.wkl`.

With the example above, `:WorklogToday` opens:

```text
~/timereg/2026/21/2026-05-18.wkl
```

If the file is missing or empty, `:WorklogToday` creates the first worklog block
using your configured defaults and inserts the current time.

`:WorklogToday [offset]` also accepts a signed day count from today: `-1` for
yesterday, `0` for today, `+1` or `1` for tomorrow, and so on. Nonzero offsets
still initialize missing or empty files with the configured worklog header, but
they do not insert the current clock time.

`:WorklogDays {count}` uses the same journal settings to scan the last N dates,
including today, from oldest to newest. `:WorklogWeek` scans the current ISO
week from Monday through Sunday. Both commands recompute each included day's
quantized summary from the latest worklog block in that file, show those daily
summaries in a scratch buffer, then append one aggregate total built from the
already-quantized daily results.

Adding `!` to either command omits the daily review sections and shows only the
aggregate weekly or range summary in the scratch buffer.

`journal.directory` uses `strftime`, so `%G/%V` may fit ISO week-based trees
better than `%Y/%V` around new year boundaries.

A common place for this file is:

```text
~/.config/nvim/lua/plugins/worklog.lua
```

Then restart Neovim and run:

```vim
:Lazy sync
```

`worklog.nvim` does not set keymaps by default. You can map the commands however
you like, for example:

```lua
vim.keymap.set("n", "<leader>wi", "<cmd>WorklogInsert<cr>", { desc = "Worklog insert time" })
vim.keymap.set("n", "<leader>wt", function()
  vim.cmd("WorklogToday " .. vim.v.count)
end, { desc = "Worklog open today / +N days" })
vim.keymap.set("n", "<leader>wT", function()
  vim.cmd("WorklogToday -" .. vim.v.count1)
end, { desc = "Worklog open -N days" })
vim.keymap.set("n", "<leader>wd", "<cmd>WorklogDays 7<cr>", { desc = "Worklog last 7 days" })
vim.keymap.set("n", "<leader>wk", "<cmd>WorklogWeek<cr>", { desc = "Worklog week report" })
vim.keymap.set("n", "<leader>wr", "<cmd>WorklogRepeat<cr>", { desc = "Worklog repeat activity" })
vim.keymap.set("n", "<leader>ww", "<cmd>WorklogCopy<cr>", { desc = "Worklog copy block" })
vim.keymap.set("n", "<leader>wo", "<cmd>WorklogOrder<cr>", { desc = "Worklog order blocks" })
vim.keymap.set("n", "<leader>ws", "<cmd>WorklogSummarize<cr>", { desc = "Worklog summarize exact" })
vim.keymap.set("n", "<leader>wq", "<cmd>WorklogQuantSum<cr>", { desc = "Worklog summarize quantized" })
vim.keymap.set("n", "<leader>wl", "<cmd>WorklogLog<cr>", { desc = "Worklog mark summary row as logged" })
vim.keymap.set("n", "<leader>wR", "<cmd>WorklogRefresh<cr>", { desc = "Worklog refresh summaries" })
vim.keymap.set("n", "]w", function()
  vim.cmd("WorklogNextDay " .. vim.v.count1)
end, { desc = "Worklog next day" })
vim.keymap.set("n", "[w", function()
  vim.cmd("WorklogPrevDay " .. vim.v.count1)
end, { desc = "Worklog previous day" })
```

`<leader>wt` opens today (inserting the current time on first creation); add a
count to jump forward, e.g. `3<leader>wt` for three days ahead. `<leader>wT`
jumps backward, e.g. `2<leader>wT` for two days ago. These jumps are always
relative to today.

`]w` and `[w` instead *step* to the next and previous day relative to the journal
file you are viewing, so repeated presses walk through your days; a count
multiplies the step, e.g. `3[w` for three days back. When the current buffer is
not a dated worklog file, they fall back to today.

## Documentation

For full format and command details, see:

```vim
:help worklog.nvim
```

For integration diagnostics, run:

```vim
:checkhealth worklog
```

This health check focuses on runtime plugin integration rather than contributor
tooling.

For internal design notes, see:

```text
docs/architecture.md
```

## Versioning and compatibility

`main` is the active development branch. Tagged releases are the compatibility
points for users who need reproducible `.wkl` parsing, summaries, and
rendering.

- `worklog.nvim` is pre-1.0, so breaking syntax or semantic changes may still
  happen, but they are called out clearly in `CHANGELOG.md`.
- The project aims to preserve existing valid `.wkl` files where practical.
- Unknown or unsupported header options are reported as diagnostics instead of
  being silently ignored.
- New trailing entry syntax such as `!L` may be treated as plain text or
  rejected by older versions.
- Patch releases may change derived results when they fix miscomputed
  behavior; those changes are documented.
- Compatibility applies to worklog blocks and their semantics. Generated
  summary text is derived output, not canonical source data.

## Development

Set up local tooling:

```sh
just install
```

This configures `git` to use the repository's `.githooks/` directory.

Local checks are split into `just static-check` and `just nvim-check`. Run
`just check` for the full local gate.

For available convenience recipes, run `just --list` or inspect `justfile`.

## License

MIT. See [LICENSE](LICENSE).
