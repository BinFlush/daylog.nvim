# worklog.nvim

A focused Neovim plugin for structured plain-text worklogs.

`worklog.nvim` helps you keep a plain-text log of what you did during the day,
then derive clean summaries for reporting.

It is useful when time tracking needs more structure than a simple list of
timestamps: repeated work items, reporting tags, work locations,
out-of-office time, exact totals, and rounded reporting totals.

## Basic example

Write timestamped entries as the day happens. Each entry runs until the next
timestamp; the final `done` line simply closes the last interval.

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
15-minute buckets by default. The `(+Nm)` beside a row is the rounding
difference from the exact time — `+` when rounded down, `-` when rounded up. Here
the exact day is 3h52m, so the rounded 3.75h total shows `(+7m)`.

## A typical day

This is the everyday loop. Each step maps a command to the question "what do I
do right now?".

**1. Install and point it at a journal folder.** With `lazy.nvim`:

```lua
{
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup({
      journal = { root = "~/worklog" }, -- where your dated files live
      auto_summary = "idle",            -- keep the summary up to date for you
    })
  end,
}
```

Restart Neovim and run `:Lazy sync`. See [Install](#install) for every option
and suggested keymaps.

**2. Start the day — `:WorklogToday`.** Opens (and creates) today's dated file.
On a fresh day it adds the header, stamps the current time, and drops you into
insert mode. Type what you are starting on:

```text
--- worklog ---
09:00 planning
```

**3. Switch tasks — `:WorklogInsert`.** When you move on to something else, run
it to stamp the current time on a new line, then type the new task. Every line
means "from this time, I was doing this":

```text
09:00 planning
10:30 fixing the login bug
```

You never type durations — the gap between two lines is how long the first task
took.

**4. Pick up a task you already have — `:WorklogRepeat`.** Put the cursor on an
earlier entry and run it. It copies that activity to the current time, so
recurring work (a standup, email, a client) is one keystroke instead of
retyping:

```text
10:30 fixing the login bug
11:15 planning              <- :WorklogRepeat on the "09:00 planning" line
```

**5. Stop the clock.** The last timestamp only closes the task before it, so end
the day with `:WorklogInsert` and type `done`:

```text
11:15 planning
12:00 done
```

**6. See your totals — `:WorklogSummarize` or `:WorklogQuantSum`.** Both add up
time per task. `Summarize` is exact; `QuantSum` rounds to tidy buckets for
reporting. With `auto_summary` set, the summary already exists from step 2 and
updates as you type, so you rarely run these by hand:

```text
--- summary exact ---
2.25h planning
0.75h fixing the login bug

--- totals exact ---
3.00h workday
```

**7. Mark what you have logged elsewhere — `:WorklogLog`.** Once you have entered
a chunk of time into your company's system, put the cursor on that summary row
and run it. It marks the underlying time with `!L` so you can see what is already
logged and not enter it twice. Run it again to unmark.

**8. Review the week — `:WorklogWeek`.** Opens a read-only report totalling every
day this week. `:WorklogDays 7` does the last seven days; add `!` (e.g.
`:WorklogWeek!`) for just the grand totals.

In short: **open today, `Insert` / `Repeat` as you work, glance at the live
summary, `Log` rows as you report them, and `Week` to review.**

## Tags, locations, and reporting metadata

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

`!L` marks an interval as logged elsewhere. Summaries split logged from unlogged
work and add a logged total; the flag is preserved by source rewrites like copy
and order.

`:WorklogLog` toggles whether a summary row has been logged elsewhere. It adds or
removes `!L` on the source entries that contributed to that row, then rebuilds
the summary. It works for exact and quantized summaries; `#ooo` rows cannot be
logged. See `:help :WorklogLog` for the full behavior.

## Commands

| Command | Effect |
| --- | --- |
| `:WorklogNew` | Create a new worklog block using configured defaults |
| `:WorklogToday [offset]` | Open today's journal, creating it on first use; a nonzero offset only navigates to another day (never creates it) |
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

On first use, `:WorklogToday` creates today's file with the first worklog block
from your defaults, inserts the current time, and appends a quantized summary so
the day is tracked from the start (live when `auto_summary` is enabled). An
optional signed offset just *navigates* to another day (`-1` yesterday, `+1`
tomorrow, and so on): it opens that day's file if it exists, or an empty buffer
if it doesn't — it never creates a file. (To start a past or future day, navigate
there and run `:WorklogNew`.) Existing files always open unchanged.

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
not a dated worklog file, they fall back to today. Like `:WorklogToday <offset>`,
stepping is navigation only: it opens an existing day, or an empty buffer for a
day with no file yet, and never creates or modifies anything — so a day you only
glance at leaves no file behind and Neovim still quits cleanly.

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
