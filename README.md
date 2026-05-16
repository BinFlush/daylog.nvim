# worklog.nvim

A focused Neovim plugin for structured plain-text worklogs.

`worklog.nvim` helps you keep a plain-text personal log for what you did
during the day, iterate on it, and derive clean summaries for reporting.

It is designed for workflows where time tracking needs more structure than a
simple list of timestamps. It supports reporting tags, work locations, out-of-office time,
exact totals, and rounded reporting totals.
Most importantly, it automatically sums identical work items together and reports the total time spent on each.


## Basic Example

Imagine we write the following during the day
```text
--- worklog ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```
Running `:WorklogQuantSum` appends a rounded summary, giving us:

```text
--- worklog ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done


--- summary quantized ---
1.75h (+2m) planning
1.50h (+2m) PR review
0.50h (+3m) bugfixes on backend

--- totals quantized ---
3.75h (+7m) workday
```
Notice, duration is given in decimal, and are rounded to nearest quarter by default. This however is configurable.

## Extended Example
We may add tags and location metadata to header or item:
```text
--- worklog #ClientA @office quantize=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

The `#tag` and `@location` metadata are sticky, so the above conceptually resolves to:

```text
08:00-10:00 planning          #ClientA   @office
10:00-13:00 implementation    #ClientA   @home
13:00-14:00 internal meeting  #internal  @home
14:00-17:00 client followup   #ClientA   @client
```

## Format

A worklog starts with a worklog header:

```text
--- worklog ---
```

The header may set initial sticky metadata and options:

```text
--- worklog #ClientA @office quantize=30 ---
```

Entries use this shape:

```text
HH:MM text [#tag|#-] [@location|@-]
```

Rules:

- `#tag` sets the current reporting tag.
- `@location` sets the current work location.
- `#-` clears the current tag.
- `@-` clears the current location.
- Omitted tag or location metadata inherits the current sticky value.
- `#ooo` is special: it counts toward `activity`, but not `workday`.
- `#ooo` is sticky too, until another tag or `#-` replaces it.
- `quantize=<minutes>` configures quantized summaries for that worklog block.
- If omitted, quantization defaults to 15 minutes.
- Non-timestamped lines under an entry are notes and move with that entry.
- A closing line such as `17:00 done` provides the end time for the previous entry.

Example with clears:

```text
--- worklog ---
08:00 planning
10:00 break #ooo
10:15 back to untagged work #-
12:00 client call #ClientA @client
13:00 back to untagged, no-location work #- @-
14:00 done
```

## Commands

| Command | Scope | Effect |
| --- | --- | --- |
| `:WorklogInsert` | Worklog under cursor | Insert current time in order and enter insert mode |
| `:WorklogRepeat` | Entry under cursor | Repeat the same activity at the current time |
| `:WorklogCopy` | Active worklog | Append a normalized editable copy |
| `:WorklogOrder` | All worklog blocks | Rewrite worklog blocks in chronological order |
| `:WorklogSummarize` | Active worklog | Append exact item, tag, location, and total summaries |
| `:WorklogQuantSum` | Active worklog | Append quantized summaries using that block’s `quantize` setting |

The active worklog is the latest `--- worklog ... ---` block in the file.

## Summaries

An interval runs from one timestamped entry to the next.

Summaries group work by:

- activity text
- effective `#tag`
- effective `@location`

Exact summaries use the raw intervals.

Quantized summaries round grouped work into buckets. The bucket size is read
from `quantize=<minutes>` on the active worklog block, or defaults to 15.

Summary rows are ordered longest-to-shortest.

Tag and location sections are omitted when they only contain placeholder buckets.
The `activity` total is omitted when it is identical to `workday`.

## Documentation

- In Neovim, see `:help worklog.nvim`.
- For internal design notes, see `docs/architecture.md`.


## Install

Example with `lazy.nvim`:

```lua
return {
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup()
  end,
}
```

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
vim.keymap.set("n", "<leader>wr", "<cmd>WorklogRepeat<cr>", { desc = "Worklog repeat activity" })
vim.keymap.set("n", "<leader>ww", "<cmd>WorklogCopy<cr>", { desc = "Worklog copy block" })
vim.keymap.set("n", "<leader>wo", "<cmd>WorklogOrder<cr>", { desc = "Worklog order blocks" })
vim.keymap.set("n", "<leader>ws", "<cmd>WorklogSummarize<cr>", { desc = "Worklog summarize exact" })
vim.keymap.set("n", "<leader>wq", "<cmd>WorklogQuantSum<cr>", { desc = "Worklog summarize quantized" })
```

## Development

Run the full suite:

```sh
nvim --headless -i NONE -u NONE \
  "+set rtp+=." \
  "+lua dofile('tests/run.lua')" \
  +qa!
```

Smoke check:

```sh
nvim --headless -u NONE \
  "+set rtp+=." \
  "+lua require('worklog').setup()" \
  +qa
```
