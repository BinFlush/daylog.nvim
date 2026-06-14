# worklog.nvim

A Neovim plugin for structured plain-text worklogs.

`worklog.nvim` helps you keep a plain-text log of what you did during the day,
then derive clean summaries for reporting.

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

A summary is automatically kept underneath the worklog:

```text
--- summary q=15 d=dec ---
1.75h (+2m) planning
1.50h (+2m) PR review
0.50h (+3m) bugfixes on backend

--- totals ---
3.75h (+7m) workday
```

Identical work items are summed automatically. Durations round to 15-minute
buckets by default (set `q=1` in the header for exact figures). The
`(+Nm)` beside a row is the rounding difference from the exact time: `+` when
rounded down, `-` when rounded up, `(+0m)` when exact. Here the exact day is
3h52m, so the rounded 3.75h total (equalling 3h45m) shows `(+7m)`.

## Basic setup
**Install and point it at a journal folder.** With `lazy.nvim`:

```lua
{
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup({
      journal = { root = "~/worklog" }, -- where your dated files live
      auto_summary = "change",            -- keep the summary up to date for you
    })
  end,
}
```

Restart Neovim and run `:Lazy sync`. See [Install](#install) for every option
and suggested keymaps.

## A typical day

**1. Start the day `:WorklogToday`.** Opens (or creates) today's dated file.
On a fresh day it adds the header, stamps the current time, and drops you into
insert mode. Type what you are starting on:

```text
--- worklog ---
09:00 planning
```

**2. Switch tasks `:WorklogInsert`.** When you move on to something else, run
it to stamp the current time on a new line, then type the new task. Every line
means "from this time, I was doing this":

```text
--- worklog ---
09:00 planning
10:30 fixing the login bug
```

You never type durations. The gap between two lines is how long the first task
took.

**3. Pick up a task you already have `:WorklogRepeat`.** Put the cursor on an
earlier entry and run it. It copies that activity to the current time, so
recurring work (a standup, email, a client) is one keystroke instead of
retyping:

```text
--- worklog ---
09:00 planning              <- at 11:15 you run :WorklogRepeat while cursor on this line
10:30 fixing the login bug
11:15 planning              <- makes this appear
```

**4. Stop the clock.** The last timestamp only closes the task before it, so end
the day with `:WorklogInsert` and type `done` (or leave it blank/anything):

```text
--- worklog ---
09:00 planning
10:30 fixing the login bug
11:15 planning
12:03 done
```

**5. See your totals.** The summary lives at the bottom of the worklog and
updates as you type (`auto_summary` defaults to `change`), so totals are always
there:

```text
--- summary q=15 d=dec ---
2.25h (+3m) planning
0.75h (+0m) fixing the login bug

--- totals ---
3.00h (+3m) workday
```

**6. Mark what you have logged elsewhere `:WorklogLog`.** Once you have entered
a chunk of time into some external system, put the cursor on that summary row and
run it. It marks the underlying time with `!L` so you can see what is already
logged and not enter it twice. Run it again to unmark.

```text
--- worklog ---
09:00 planning !L
10:30 fixing the login bug
11:15 planning !L
12:03 done

--- summary q=15 d=dec ---
2.25h (+3m) planning !L             <- :WorklogLog while cursor here marks
0.75h (+0m) fixing the login bug        the above entries and creates the
                                        --- logged --- block below
--- logged ---
2.25h (+3m) logged
0.75h (+0m) unlogged

--- totals ---
3.00h (+3m) workday
```

**7. Review the week `:WorklogWeek`.** Opens a read-only report totalling every
day this week. `:WorklogDays 7` does the last seven days; add `!` (e.g.
`:WorklogWeek!`) for just the grand totals. With `auto_summary` on it stays live,
rebuilding as you edit the days it covers (including unsaved buffers).

In short: **open today, `Insert` / `Repeat` as you work, glance at the live
summary, `Log` rows as you report them, and `Week` to review.**

## Tags, locations, and reporting metadata

You can add reporting tags, locations, and a custom quantization bucket.
Example where each task is rounded to nearest half hour:
```text
--- worklog #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

`#tag` and `@location` are sticky. When an entry omits one of them, it inherits
the previous value:

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
#-             clear current tag (only useful if untagged items are explicitly needed)
@-             clear current location (only useful if unlocated items are explicitly needed)
q=30    round summaries to 30-minute buckets
d=hm  render summary durations as hours:minutes rather than decimal notation
```

## Commands

| Command | Effect |
| --- | --- |
| `:WorklogToday [offset]` | Open today's journal, creating it on first use; a nonzero offset only navigates to another day (never creates it) |
| `:WorklogNextDay [count]` | Step forward `count` days (default 1) relative to the open journal file, falling back to today |
| `:WorklogPrevDay [count]` | Step backward `count` days (default 1) relative to the open journal file, falling back to today |
| `:WorklogDays[!] {count}` | Open the last N journal days report; `!` shows only the aggregate range summary |
| `:WorklogWeek[!]` | Open this week's journal report; `!` shows only the aggregate weekly summary |
| `:WorklogInsert [source]` | Insert current time in order and enter insert mode; with a configured source name, pick a work item to insert (see [Sources](#sources)) |
| `:WorklogRepeat` | Repeat the activity under the cursor at the current time; on another day's file, bring it into today instead |
| `:WorklogCopy` | Append a normalized editable copy, with its own summary |
| `:WorklogOrder` | Rewrite worklog blocks in chronological order |
| `:WorklogLog` | Toggle the logged state of the main summary row under the cursor (add or remove `!L` on the contributing source entries) |
| `:WorklogRefresh` | Rebuild every summary to match its entries, creating one for any worklog that lacks it |
| `:WorklogSync [source]` | Refresh a source's local work-item cache, or every configured source (see [Sources](#sources)) |

The active worklog is always the latest `--- worklog ... ---` block in the file.

## Live summaries

Worklogs created by `:WorklogToday` and `:WorklogCopy` carry a summary from the
start. By default (`auto_summary = "change"`) it stays live as you type. The same
setting keeps open `:WorklogWeek` / `:WorklogDays` reports current, rebuilding in
place as the days they cover change (including unsaved edits in open buffers).

The summary header echoes the worklog's `q=`/`d=` as a read-only banner
(`--- summary q=15 d=dec ---`); it is regenerated on refresh, so change the
quantization or duration format on the worklog header, not the summary.

| `auto_summary` | When summaries refresh |
| --- | --- |
| `"change"` (default) | Shortly after edits settle (debounced) |
| `"idle"` | When you pause or leave insert mode |
| `"save"` | On write (`:w`) |
| `"off"` (or `false`) | Never automatically; use `:WorklogRefresh` |

`:WorklogRefresh` rebuilds every summary in the buffer by hand, and creates one for
any valid worklog that has none — so a summary you delete comes back. It never
removes a summary. While a worklog is invalid (for example its timestamps are out of
order) it is left alone rather than churned, and the problem is reported as a buffer
diagnostic that clears once you fix it.

## Sources

Pull work items from an external tracker into a worklog entry. **Azure DevOps**
is built in. Configure a named source, then run `:WorklogInsert <name>` to pick a
work item and insert it as `{id} {title}` at the current time.

```lua
require("worklog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",
      project = "Platform",
      token = function()
        return vim.trim(vim.fn.system({ "pass", "show", "ado/pat" }))
      end,
      -- optional: query_id (a saved ADO query), query (raw WIQL), template, ttl
    },
  },
})

vim.keymap.set("n", "<leader>wa", "<cmd>WorklogInsert ADO<cr>", { desc = "Worklog insert ADO item" })
```

- **The picker is `vim.ui.select`**, so Telescope / fzf-lua / snacks / mini.pick
  take over automatically when installed — no hard dependency, and no picker is
  required.
- **Picking is offline and instant.** It reads a per-source cache; the cache
  refreshes in the background when stale and on `:WorklogSync`. Only syncing
  touches the network (via `curl`).
- **Live search with Telescope.** When Telescope is installed, typing in the
  picker searches the whole tracker as you go (debounced); your cached items show
  at an empty prompt. Without it, the picker filters your cached items. Custom
  sources opt in via `search(query, cb)`.
- **Your PAT is a function**, resolved only at sync time and never written to the
  cache — read it from the environment or a password manager.
- **Scope is yours.** The default fetch is "assigned to me, active, recently
  changed"; point at a saved ADO query (`query_id`) or paste raw WIQL (`query`).
- Cancelling the picker falls back to a plain bare timestamp, so
  `:WorklogInsert <name>` is a non-committal enhancement of `:WorklogInsert`.

Multiple sources can coexist (several ADO orgs, plus your own). See
`:help worklog-sources` for the full reference.

**Write your own source** (Jira, GitHub Issues, …) by registering a table with
`fetch` / `format_item` / `to_entry_text` (and an optional `search`):
`require("worklog.sources.registry").register("MySource", source)`. Inserted text
is sanitized for you, so a title can't corrupt the worklog. See
`:help worklog-custom-source` for the contract and a worked example.

## Limitations and syntax gotchas

- The final timestamp closes the previous interval and has no duration of its own.
- Entries use `HH:MM`; ranges, dates, and seconds are not supported.
- Keep times ordered before summarizing; use `:WorklogOrder` to rewrite blocks.
- `#tag` and `@location` are sticky until replaced or cleared with `#-` and `@-`.
- Only trailing metadata tokens are parsed as metadata; multiple trailing tags or locations are invalid.
- `#ooo` counts as activity but is excluded from workday totals.
- Main summary rows do not split by location; locations are reported separately.
- Each worklog has exactly one summary, always quantized to its `q=<minutes>` bucket (`q=1` for exact). It is regenerable derived output and owns the tail of its worklog, so keep notes on entries, not in the summary.

## Requirements

- Neovim 0.8.0 or newer
- `curl` — only when using external [sources](#sources)

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
        quantize_minutes = 15,
        duration_format = "dec",
      },
      journal = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
      auto_summary = "change",
    })
  end,
}
```

Every option is optional. The default fields are `tag`, `location`,
`quantize_minutes`, and `duration_format`. `auto_summary` (`"change"` by default,
or `"idle"` / `"save"` / `"off"`) controls when summaries refresh automatically,
see [Live summaries](#live-summaries).

Journal settings are optional too. `journal.root` is the base directory for
`:WorklogToday`; `journal.directory` is an optional `strftime` template under it;
the filename is always `YYYY-MM-DD.wkl`. With the example above, `:WorklogToday`
opens `~/timereg/2026/21/2026-05-18.wkl`. Use `%G/%V` instead of `%Y/%V` if you
want ISO week-based trees that stay correct around new-year boundaries.

Drop this in a file such as `~/.config/nvim/lua/plugins/worklog.lua`, restart
Neovim, and run `:Lazy sync`.

`worklog.nvim` sets no keymaps by default. Map the commands however you like, for
example:

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
vim.keymap.set("n", "<leader>wl", "<cmd>WorklogLog<cr>", { desc = "Worklog mark summary row as logged" })
vim.keymap.set("n", "<leader>wR", "<cmd>WorklogRefresh<cr>", { desc = "Worklog refresh summaries" })
vim.keymap.set("n", "]w", function()
  vim.cmd("WorklogNextDay " .. vim.v.count1)
end, { desc = "Worklog next day" })
vim.keymap.set("n", "[w", function()
  vim.cmd("WorklogPrevDay " .. vim.v.count1)
end, { desc = "Worklog previous day" })
```

With these maps a count picks the day: `3<leader>wt` opens three days ahead and
`2<leader>wT` two days back (both relative to today), while `3]w` / `3[w` step
three days forward or back relative to the file you are viewing (falling back to
today off a non-journal buffer).

## Documentation

- `:help worklog.nvim` for full format and command details.
- `:checkhealth worklog` for integration diagnostics.
- `docs/architecture.md` for internal design notes.

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

## Releasing

Maintainers cut a release with one command:

```sh
just release 0.6.0
```

It checks the tree is clean and on `main`, renames the `## Unreleased` section of
`CHANGELOG.md` to the version and today's date, commits as `Release 0.6.0`, and tags
`v0.6.0`. Then:

```sh
git push origin main --follow-tags
```

publishes a GitHub Release whose notes are that changelog section, via
`.github/workflows/release.yml` (triggered by the `v*` tag).

## License

MIT. See [LICENSE](LICENSE).
