# worklog.nvim

Minimal Neovim plugin for plain-text worklogs.

Keep timestamped lines inside `--- worklog ---` blocks, then derive normalized
copies, ordering, and summaries from them.

The intended use case is simple: jot down what you are doing as the day moves,
keep the source log editable and human-readable, and only derive the neat
reporting view when you need it.

For example, you might keep a `.wkl` file open during work, add quick lines like
`08:21 negotiate with goose #sales`, fix rough timestamps later, then append an
exact or quantized summary when it is time to report hours.

`*.wkl` is detected as filetype `worklog` when the plugin is loaded.

## Install

```lua
{
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup()
  end,
}
```

Commands:

- `:WorklogInsert`
- `:WorklogRepeat`
- `:WorklogCopy`
- `:WorklogOrder`
- `:WorklogSummarize`
- `:WorklogQuantSum`

## Format

With a default label:

```text
--- worklog default=#ProjectOrion ---
08:04 bake strudel
08:21 negotiate with goose #sales
08:52 coffee with ghost #ooo
10:00 done
```

Without a default label:

```text
--- worklog ---
08:04 bake strudel
08:21 negotiate with goose #sales
08:52 coffee with ghost #ooo
10:00 done
```

Rules:

- The first line must be `--- worklog ---` or `--- worklog default=#label ---`.
- Later editable worklog blocks use `--- worklog ---`.
- Entry syntax is `HH:MM [text] [#label]`.
- At most one trailing `#label` is allowed.
- If a default label exists, unlabeled entries inherit it.
- Otherwise unlabeled entries stay unlabeled.
- `#ooo` is special: it counts toward `activity`, but not `workday`.
- Non-timestamped lines under an entry are notes; they move with that entry when copied or ordered.
- A closing line such as `10:00 done` just provides the end time for the previous entry.

## Commands

| Command | Scope | Effect |
| --- | --- | --- |
| `:WorklogInsert` | Worklog under cursor, including header | Insert current time in order and enter insert mode |
| `:WorklogRepeat` | Current entry in worklog under cursor | Reinsert the same activity at the current time |
| `:WorklogCopy` | Active worklog | Append a normalized `--- worklog ---` copy |
| `:WorklogOrder` | All worklog blocks | Rewrite each block in chronological order |
| `:WorklogSummarize` | Active worklog | Append exact grouped summary, label totals, and totals |
| `:WorklogQuantSum` | Active worklog | Append quantized grouped summary, label totals, and totals |

General behavior:

- The active worklog is the latest `--- worklog ... ---` block in the file.
- `:WorklogInsert` and `:WorklogRepeat` use the block containing the cursor.
- `:WorklogCopy`, `:WorklogSummarize`, and `:WorklogQuantSum` use the active worklog.
- Commands validate only the blocks they operate on.
- `:WorklogOrder` can repair decreasing timestamps, but malformed entry lines still block it.
- Equal timestamps are allowed and keep their relative order.

## Summary Semantics

- An interval is the time from one entry to the next.
- Summary items group by `text + effective label`.
- Effective label = explicit trailing label, otherwise the file default, otherwise unlabeled.
- Exact output contains `--- summary exact ---`, `--- labels exact ---`, and `--- totals exact ---`.
- Quantized output contains `--- summary quantized ---`, `--- labels quantized ---`, and `--- totals quantized ---`.
- Item rows and label rows are sorted longest-to-shortest.
- Equal quantized display durations are ordered by exact grouped duration.
- In label sections, unlabeled time is rendered as `(unlabeled)`.

Quantized summary rules:

1. Compute exact intervals from timestamps.
2. Group identical items by text and effective label.
3. Round total `activity` to the nearest 15 minutes.
4. Round each grouped item down to 15 minutes.
5. Distribute the remaining 15-minute blocks to the largest remainders.

Deltas are rendered as `exact minutes - displayed minutes`, so a positive delta
means the exact grouped time was longer than the displayed row.

## Example

Source worklog:

```text
--- worklog default=#ProjectOrion ---
08:04 bake strudel
08:21 negotiate with goose #sales
08:33 bake strudel
08:52 coffee with ghost #ooo
09:11 polish trombone
09:36 bake strudel
10:00 done
```

Exact summary:

```text
--- summary exact ---
1.00h bake strudel
0.42h polish trombone
0.32h coffee with ghost (ooo)
0.20h negotiate with goose #sales

--- labels exact ---
1.42h #ProjectOrion
0.32h #ooo
0.20h #sales

--- totals exact ---
1.93h activity
1.62h workday
```

Quantized summary:

```text
--- summary quantized ---
1.00h (+0m) bake strudel
0.50h (-5m) polish trombone
0.25h (+4m) coffee with ghost (ooo)
0.25h (-3m) negotiate with goose #sales

--- labels quantized ---
1.50h (-5m) #ProjectOrion
0.25h (+4m) #ooo
0.25h (-3m) #sales

--- totals quantized ---
2.00h (-4m) activity
1.75h (-8m) workday
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
