# worklog.nvim

Minimal Neovim plugin for plain-text worklogs.

Keep timestamped lines inside `--- worklog ---` blocks, then derive normalized
copies, ordering, and summaries from them.

The intended use case is simple: jot down what you are doing as the day moves,
keep the source log editable and human-readable, and only derive the neat
reporting view when you need it.

For example, you might keep a `.wkl` file open during work, add quick lines like
`08:21 negotiate with goose #sales @client`, fix rough timestamps later, then
append an exact or quantized summary when it is time to report hours.

`*.wkl` is detected as filetype `worklog` when the plugin is loaded.

## Sticky Metadata

```text
--- worklog #ClientA @office ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

- `#tag` and `@location` are sticky inside a worklog block.
- When either token is omitted, the entry inherits the current sticky value.
- Write a new timestamped entry whenever the tag or location changes.
- `#ooo` is sticky too, and its intervals count toward `activity` but not `workday`.
- There is currently no syntax for clearing a sticky tag or location back to empty.

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

With sticky tag and location metadata plus custom quantization:

```text
--- worklog #ProjectOrion @office quantize=30 ---
08:04 bake strudel
08:21 negotiate with goose #sales @client
08:52 coffee with ghost #ooo @home
10:00 done #ProjectOrion @office
```

Without initial sticky metadata:

```text
--- worklog ---
08:04 bake strudel
08:21 negotiate with goose #sales
08:52 coffee with ghost @home
10:00 done
```

Rules:

- The first line must be a worklog header, such as `--- worklog ---` or `--- worklog #ClientA @office quantize=30 ---`.
- Any worklog header may initialize sticky `#tag` and `@location` metadata for that block.
- Any worklog header may also declare `quantize=<minutes>` for quantized summaries of that block; if omitted, quantization defaults to 15 minutes.
- `quantize` must be a positive integer number of minutes.
- Entry syntax is `HH:MM [text] [#tag] [@location]`.
- At most one trailing `#tag` and one trailing `@location` are allowed on each entry.
- `#tag` and `@location` are sticky inside a block.
- An entry that omits one or both metadata tokens inherits the current sticky values.
- `#ooo` is special: it counts toward `activity`, but not `workday`, and it stays sticky until another tag replaces it.
- There is currently no `clear tag` or `clear location` token; once a sticky value is set inside a block, later entries inherit it until another value replaces it.
- Non-timestamped lines under an entry are notes; they move with that entry when copied or ordered.
- A closing line such as `10:00 done` just provides the end time for the previous entry.

Example:

```text
--- worklog #ClientA @office quantize=30 ---
08:00 plan migration
10:30 implement migration @home
13:00 internal meeting #internal
15:00 client followup #ClientA @client
17:00 done
```

Effective intervals:

```text
08:00-10:30 plan migration      #ClientA  @office
10:30-13:00 implement migration #ClientA  @home
13:00-15:00 internal meeting    #internal @home
15:00-17:00 client followup     #ClientA  @client
```

## Commands

| Command | Scope | Effect |
| --- | --- | --- |
| `:WorklogInsert` | Worklog under cursor, including header | Insert current time in order and enter insert mode |
| `:WorklogRepeat` | Current entry in worklog under cursor | Reinsert the same activity at the current time |
| `:WorklogCopy` | Active worklog | Append a normalized `--- worklog ... ---` copy |
| `:WorklogOrder` | All worklog blocks | Rewrite each block in chronological order |
| `:WorklogSummarize` | Active worklog | Append exact grouped summary, tag totals, location totals, and totals |
| `:WorklogQuantSum` | Active worklog | Append quantized grouped summary, tag totals, location totals, and totals |

General behavior:

- The active worklog is the latest `--- worklog ... ---` block in the file.
- `:WorklogInsert` and `:WorklogRepeat` use the block containing the cursor.
- `:WorklogCopy`, `:WorklogSummarize`, and `:WorklogQuantSum` use the active worklog.
- Commands validate only the blocks they operate on.
- `:WorklogOrder` can repair decreasing timestamps, but malformed entry lines still block it.
- `:WorklogOrder` also refuses reorders that would require clearing a sticky tag or location implicitly, because the syntax has no reset token.
- `:WorklogRepeat` can fail for the same reason when repeating an older entry into a later sticky context.
- Equal timestamps are allowed and keep their relative order.

## Summary Semantics

- An interval is the time from one entry to the next.
- Summary items group by `text + effective tag + effective location`.
- Exact output contains `--- summary exact ---`, `--- tags exact ---`, `--- locations exact ---`, and `--- totals exact ---`.
- Quantized output contains `--- summary quantized ---`, `--- tags quantized ---`, `--- locations quantized ---`, and `--- totals quantized ---`.
- Quantized summaries use `quantize=<minutes>` from the active worklog header, defaulting to 15 for that block.
- Item rows, tag rows, and location rows are sorted longest-to-shortest.
- Equal quantized display durations are ordered by exact grouped duration.
- In tag sections, missing tags are rendered as `(untagged)`.
- In location sections, missing locations are rendered as `(no location)`.

Quantized summary rules:

1. Compute exact intervals from timestamps.
2. Group identical items by text and effective metadata.
3. Round total `activity` to the nearest configured quantization bucket.
4. Round each grouped item down to that bucket.
5. Distribute the remaining bucket-sized blocks to the largest remainders.

Deltas are rendered as `exact minutes - displayed minutes`, so a positive delta
means the exact grouped time was longer than the displayed row.

## Example

Source worklog:

```text
--- worklog #ProjectOrion @office ---
08:04 bake strudel
08:21 negotiate with goose #sales @client
08:33 bake strudel #ProjectOrion @office
08:52 coffee with ghost #ooo @home
09:11 polish trombone #ProjectOrion @office
09:36 bake strudel
10:00 done
```

Exact summary:

```text
--- summary exact ---
1.00h bake strudel #ProjectOrion @office
0.42h polish trombone #ProjectOrion @office
0.32h coffee with ghost #ooo @home
0.20h negotiate with goose #sales @client

--- tags exact ---
1.42h #ProjectOrion
0.32h #ooo
0.20h #sales

--- locations exact ---
1.42h @office
0.32h @home
0.20h @client

--- totals exact ---
1.93h activity
1.62h workday
```

Quantized summary:

```text
--- summary quantized ---
1.00h (+0m) bake strudel #ProjectOrion @office
0.50h (-5m) polish trombone #ProjectOrion @office
0.25h (+4m) coffee with ghost #ooo @home
0.25h (-3m) negotiate with goose #sales @client

--- tags quantized ---
1.50h (-5m) #ProjectOrion
0.25h (+4m) #ooo
0.25h (-3m) #sales

--- locations quantized ---
1.50h (-5m) @office
0.25h (+4m) @home
0.25h (-3m) @client

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
