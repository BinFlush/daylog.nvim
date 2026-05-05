# worklog.nvim

Small Neovim plugin for keeping a plain-text worklog.

The format is deliberately simple: write timestamped lines in a buffer, then
append derived blocks from the latest worklog.

## Input Format

A worklog line starts with a valid `HH:MM` time and may be followed by text.

```text
08:04 bake strudel
08:21 negotiate with goose
08:33 bake strudel
08:52 coffee with ghost #ooo
09:11 polish trombone
09:36 bake strudel
10:00 done
```

- each entry lasts until the next timestamped entry
- non-timestamped lines (such as this one) are ignored
- a line with only a valid time is allowed and is useful as a closing timestamp
- `#ooo` marks an entry as out of office
- out-of-office entries are included in `activity`, but excluded from `workday`
- identical items are grouped by text and `#ooo` state during summary
- the final line is usually a closing marker such as `done`, so the previous
  item has an end time, but the exact text does not matter.

## Active Worklog

Most commands operate on the active worklog.

- if the buffer contains one or more `--- worklog ---` headers, the latest one
  is the active worklog
- if there is no `--- worklog ---` header, the entire buffer is treated as the
  active worklog
- the active worklog ends at the next `--- ... ---` header, or at end of file

This makes it easy to keep raw notes at the top of the file and append derived
blocks below.

`WorklogCopy`, `WorklogSummarize`, and `WorklogQuantSum` use the active
worklog. `WorklogRepeat` instead uses the worklog body containing the cursor.

All commands except `WorklogOrder` stop if any worklog block in the buffer has
decreasing timestamps.

## Commands

### `:WorklogInsert`

Insert the current time into the worklog block containing the cursor.

Use this while logging live in a worklog.

- the cursor must be inside a worklog block
- the new entry is inserted in time order
- equal timestamps stay grouped together
- insert mode starts on the new line

### `:WorklogRepeat`

Repeat the activity under the cursor at the current time.

- the cursor line must be a valid worklog line
- the cursor must be inside a worklog block
- the new entry is inserted in time order
- equal timestamps stay grouped together
- any following summary or totals blocks are left in place

### `:WorklogCopy`

Append a new `--- worklog ---` block containing the active worklog unchanged.

Use this when you want to iteratively refine timestamps or descriptions by hand
while keeping the previous version above as a reference.

- copied items are normalized the same way as `:WorklogOrder`
- trailing empty lines attached to an item are removed in the copied block

### `:WorklogOrder`

Reorder every worklog block in the buffer by timestamp.

- timestamped lines are sorted in ascending time order
- equal timestamps are allowed and keep their original relative order
- non-timestamped lines after a timestamped line move with that line
- non-timestamped lines before the first timestamped line in a block stay at the top
- trailing empty lines attached to an item are removed

### `:WorklogSummarize`

Append an exact grouped summary for the active worklog.

- intervals are computed from the original timestamps
- repeated items are grouped together
- output is rendered in decimal hours
- `activity` includes all grouped items
- `workday` excludes grouped items marked `#ooo`

### `:WorklogQuantSum`

Append a grouped summary whose item durations are quantized to 15-minute blocks.

- intervals are still computed from the original timestamps
- identical items are grouped before quantization
- output is rendered in decimal hours
- each grouped row shows a signed minute delta of exact minus quantized time
- `activity` is the sum of all quantized grouped items
- `workday` is the sum of quantized grouped items not marked `#ooo`

## Quantized Summary Rules

`WorklogQuantSum` uses this algorithm:

1. compute exact intervals from the raw timestamps
2. group identical items by text and `#ooo` state
3. round the total `activity` time to the nearest 15 minutes
4. round each grouped item down to a 15-minute block
5. distribute the remaining 15-minute blocks to the largest remainders

This keeps the quantized summary close to the exact total while making the
displayed grouped totals add up cleanly.

Each displayed grouped row also includes a signed minute delta in parentheses.
The delta is `exact grouped minutes - displayed quantized minutes`, so a
positive value means the exact grouped time was longer than the displayed row.

One important consequence:

- non-`#ooo` grouped rows will always sum exactly to `workday`
- all grouped rows, including `#ooo`, participate in the same quantization pass

## Ordering Rules

- timestamps within a worklog must not decrease
- equal timestamps are allowed
- if a command finds decreasing timestamps anywhere in the buffer, it stops and
  warns with the absolute line numbers of the first offending pair
- the warning suggests either fixing the lines manually or running
  `:WorklogOrder`

## Examples

### Example: exact grouped summary

Input worklog:

```text
08:04 bake strudel
08:21 negotiate with goose
08:33 bake strudel
08:52 coffee with ghost #ooo
09:11 polish trombone
09:36 bake strudel
10:00 done
```

`bake strudel` appears three times. The summary groups those intervals together and renders the result in decimal hours.

Exact summary:

```text
--- summary exact ---
1.00h bake strudel
0.20h negotiate with goose
0.32h coffee with ghost (ooo)
0.42h polish trombone

--- totals exact ---
1.93h activity
1.62h workday
```

Here:

- `activity` includes `coffee with ghost (ooo)`
- `workday` excludes it
- the row totals are exact, not rounded to 15-minute blocks

### Example: quantized grouped summary

Using the same input worklog `:WorklogQuantSum` appends:

```text
--- summary quantized ---
1.00h (+0m) bake strudel
0.25h (-3m) negotiate with goose
0.25h (+4m) coffee with ghost (ooo)
0.50h (-5m) polish trombone

--- totals quantized ---
2.00h activity
1.75h workday
```

Here:

- the exact `activity` total of `1.93h` is rounded to `2.00h`
- grouped items are rounded together, not one interval at a time
- the displayed grouped rows add up exactly to the displayed totals
- the signed minute delta shows how each displayed row differs from the exact grouped time

### Example: copying a worklog block

Input buffer:

```text
08:04 bake strudel
08:21 negotiate with goose
08:33 bake strudel
10:00 done
```

After `:WorklogCopy`:

```text
08:04 bake strudel
08:21 negotiate with goose
08:33 bake strudel
10:00 done

--- worklog ---
08:04 bake strudel
08:21 negotiate with goose
08:33 bake strudel
10:00 done
```

The copied block becomes the latest `--- worklog ---` block, so later commands
that use the active worklog operate on that block rather than on the whole
buffer.

### Example: ordering a worklog block

Input buffer:

```text
08:30 bake strudel
note about apples
08:00 negotiate with goose
09:00 done
```

After `:WorklogOrder`:

```text
08:00 negotiate with goose
08:30 bake strudel
note about apples
09:00 done
```

The note moves with `08:30 bake strudel`, and trailing empty lines attached to
an item are removed.

### Example: active worklog selection

Input buffer:

```text
08:00 draft potion recipe
09:00 done

--- worklog ---
08:15 bake strudel
08:45 mail wizard council
09:00 done

--- summary quantized ---
0.50h (+0m) bake strudel
0.25h (+0m) mail wizard council

--- totals quantized ---
0.75h activity
0.75h workday
```

The active worklog is:

```text
08:15 bake strudel
08:45 mail wizard council
09:00 done
```

The older lines at the top and the appended summary are ignored for the next
operation.

## Suggested Workflow

One simple workflow is:

1. jot down raw timestamped lines during the day
2. At the end of the day, use `:WorklogCopy` to create a new editable worklog block, if need be
3. adjust timestamps and texts in the copied block if needed
4. run `:WorklogSummarize` for exact totals
5. run `:WorklogQuantSum` when you want grouped 15-minute reporting totals

This keeps the source log simple while making refinement and reporting cheap.

## Install

Install with your plugin manager of choice, then call
`require("worklog").setup()` to register the commands.

Example with `lazy.nvim`:

```lua
{
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup()
  end,
}
```

After the plugin is loaded, the `:WorklogInsert`, `:WorklogCopy`,
`:WorklogRepeat`, `:WorklogOrder`, `:WorklogSummarize`, and `:WorklogQuantSum`
commands are available in normal buffers.

## Example Keymaps

Example mappings:

```lua
vim.keymap.set("n", "<leader>wi", "<cmd>WorklogInsert<cr>", { desc = "Worklog insert time" })
vim.keymap.set("n", "<leader>wr", "<cmd>WorklogRepeat<cr>", { desc = "Worklog repeat activity" })
vim.keymap.set("n", "<leader>ww", "<cmd>WorklogCopy<cr>", { desc = "Worklog copy block" })
vim.keymap.set("n", "<leader>wo", "<cmd>WorklogOrder<cr>", { desc = "Worklog order blocks" })
vim.keymap.set("n", "<leader>ws", "<cmd>WorklogSummarize<cr>", { desc = "Worklog summarize exact" })
vim.keymap.set("n", "<leader>wq", "<cmd>WorklogQuantSum<cr>", { desc = "Worklog summarize quantized" })
```

## Development

Run the checked-in headless test suite with:

```sh
nvim --headless -i NONE -u NONE \
  "+set rtp+=." \
  "+lua dofile('tests/run.lua')" \
  +qa!
```

There is also a simple tracked pre-commit hook script at
`.githooks/pre-commit`. To use it locally:

```sh
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```
