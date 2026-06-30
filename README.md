# daylog.nvim

Plain-text time tracking for Neovim — you log timestamps, daylog does the timesheet math.

```text
--- log ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```

It reads the gap between timestamps as a duration and keeps a summary below, refreshed as you
type:

```text
--- summary q=15 d=dec ---
1.75h (+2m) planning
1.50h (+2m) PR review
0.50h (+3m) bugfixes on backend

--- totals ---
3.75h (+7m) workday
```

Repeated tasks add up; durations round to buckets (15 min by default, `q=1` for exact). The
`(+Nm)` is each row's rounding error.

In the editor each activity gets its own color — down the left margin and on its summary row — and
the optional `:Daylog bar` draws a proportional, color-matched timeline of the day at the bottom.

## Install

Add `BinFlush/daylog.nvim` with any plugin manager — it highlights and edits `.day` files the
moment it loads, no `setup()` required. The dated-day workflow (`:Daylog today`, day navigation,
reports) needs one setting: a folder for your day files.

```lua
require("daylog").setup({ daybook = { root = "~/daylog" } })
```

That call works from any plugin manager's config. With
[lazy.nvim](https://github.com/folke/lazy.nvim), `opts` runs it for you instead:

```lua
{ "BinFlush/daylog.nvim", opts = { daybook = { root = "~/daylog" } } }
```

Requires Neovim 0.8+ (and `curl`, only for external [sources](#sources)).

## Usage

- **`:Daylog today`** opens today's file (a plain-text `YYYY-MM-DD.day`), creating it on the day's
  first run — which stamps the time and starts insert mode. Type what you're working on.
- **`:Daylog insert`** stamps the current time for the next task. You never type durations.
- **`:Daylog repeat`** re-stamps an earlier activity (a standup, a recurring call) at the current
  time — cursor on its entry or summary row.
- End the day with `:Daylog insert` then `done` — the last timestamp closes the task before it.
- **`:Daylog log`** marks a summary row's time as reported elsewhere (`!L`); run it again to unmark.
- **`:Daylog report monday..`** opens a live, read-only multi-day report (`report 7`, or any date
  range).

Add a tag (`#tag`) or location (`@location`) in the header or on any entry — both sticky until
changed — or a rounding bucket (`q=`) in the header:

```text
--- log #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 client meeting #internal
17:00 done
```

The rest of the grammar (`#-` / `@-` to clear, `#ooo`, `!L`, `=> alias`, `d=hm`) is in
`:help daylog-format`.

## Commands

| Command | Effect |
| --- | --- |
| `:Daylog` / `:Daylog today` | Open today's daylog, creating and stamping it on first use |
| `:Daylog day [when]` | Open/create a specific day (no time stamp) — `monday`, `-1`, `+2`, `2026-05-10` |
| `:Daylog next [count]` / `:Daylog prev [count]` | Jump to the next / previous logged day, skipping empty days (`[count]` jumps that many) |
| `:Daylog[!] insert [source]` | Stamp the current time; with a source, pick a work item; `!` opens a fuzzy picker of your recent activities + every source's items |
| `:Daylog repeat` | Repeat the activity under the cursor (entry or summary row) at the current time |
| `:Daylog[!] report {range}` | Open a multi-day report — a count, a date range, or tokens like `monday..` (`!` for the range summary only — drops the per-day sections) |
| `:Daylog export csv\|json [range]` | Export a day or range's summary as CSV/JSON into a scratch buffer (`:w` or yank) for a timesheet / invoicing / a script |
| `:Daylog log` | Toggle the logged (`!L`) state of the summary row under the cursor |
| `:Daylog balance [steps]` | Nudge the rounding of the row (or entry) under the cursor by ±N q-steps (`0` clears) |
| `:[range]Daylog rename [name\|source]` | Rename the entry's text or a `#tag`/`@location` under the cursor; over a visual range, set every selected entry to one description (not activity summary rows — use `map` for the report label) |
| `:[range]Daylog[!] map [label\|source]` | Map the entry, a summary row's entries, or a visual selection to a report label (`=> alias`); `!` clears |
| `:Daylog split [w1 w2 …]` | Split the activity on the summary row into weighted sub-activities, preserving its total |
| `:Daylog copy` | Append an editable copy of the active log (the copy becomes active) |
| `:Daylog new` | Scaffold a fresh `--- log ---` block in the current buffer (the new block becomes active) |
| `:Daylog order` | Rewrite every log in the buffer in chronological order |
| `:Daylog refresh` | Rebuild every summary to match its entries |
| `:Daylog sync [source]` | Refresh a source's cached work items |
| `:Daylog keys` | Show the daylog keymaps + commands in a popup (also `g?` in `.day` files) |
| `:Daylog bar` | Toggle a color-coded time bar — a panel at the window's bottom showing the day's activities, sized by time spent |

`:help daylog-commands` has the full rules.

## Keymaps

daylog sets no keys. For a ready-made set:

```lua
require("daylog").setup({ keymaps = true })
```

Buffer-locally in `.day` files: `]d` / `[d` between days (count-aware) and a `<leader>d` cluster
(`di` insert, `dI` pick activity, `dr` repeat, `dn` new, `dc` copy, `do` order, `dl` log, `dm` map,
`dR` rename, `df` refresh, `db` time bar; `dm` / `dR` also act over a visual selection) — it rides your `<leader>`,
so set `mapleader` to taste (space → `<Space>di`). Each map is labelled for which-key, and `g?`
(or `:Daylog keys`) shows a cheatsheet. Pass `{ ["<lhs>"] = "<rhs>", ... }` for your own.

To bind keys yourself, every verb is a `:Daylog <verb>` command and a Lua function
(`:help daylog-lua` lists the names):

```lua
vim.keymap.set("n", "<leader>dt", "<Cmd>Daylog today<CR>")
vim.keymap.set("n", "]d", function() require("daylog").next_day(vim.v.count1) end) -- count-aware
vim.keymap.set("x", "<leader>dm", ":Daylog map<cr>") -- visual range; the command form passes it
```

Use the function form when you want a count or an argument.

## Sources

Pull work items from a tracker into an entry. **Azure DevOps** is built in: configure a named
source, then `:Daylog insert <name>` picks an item and inserts it as `{id} {title}`.
`:Daylog! insert` pools every source's items with your recent activities into one fuzzy list,
ranked by what you log most often and recently.

```lua
require("daylog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",
      project = "Platform",
      token = function()
        return vim.trim(vim.fn.system({ "pass", "show", "daylog/ado-pat" }))
      end,
    },
  },
})
```

Picking reads a local cache — offline and instant; `:Daylog sync` refreshes it over the network.
Telescope gives a fuzzy picker; otherwise `vim.ui.select` (so fzf-lua / snacks / mini.pick work
too). For live, as-you-type search of the tracker (requires Telescope), set `search = true`.

- **Token setup:** [docs/azure-devops.md](docs/azure-devops.md).
- **More options** (multiple projects, saved queries, templates): `:help daylog-sources`.
- **Your own tracker** (Jira, GitHub Issues, …): `:help daylog-custom-source`.

## Configuration

```lua
require("daylog").setup({
  defaults = { tag = "ClientA", location = "office", quantize_minutes = 15, duration_format = "dec" },
  daybook = { root = "~/daylog", directory = "%Y/%V" }, -- directory is an optional strftime template
  auto_summary = "change", -- change | idle | save | off
  auto_timezone = true, -- record UTC offset + DST/travel drift so a clock change never skews a duration
  time_bar = false, -- show the color-coded time bar by default (:Daylog bar / <leader>db toggles it)
  time_bar_hover = false, -- mouse-hover tooltip on the bar (time + activity); also needs `:set mousemoveevent`
})
```

All optional. `defaults` seed each new day's header; `daybook.root` is where dated files live
(always `YYYY-MM-DD.day`). `auto_summary` controls when summaries refresh (`off` = only on
`:Daylog refresh`). Full reference: `:help daylog-config`.

## More

- `:help daylog.nvim` — format, commands, and every option.
- `:checkhealth daylog` — verify your setup.
- daylog is pre-1.0; breaking changes are listed in [CHANGELOG.md](CHANGELOG.md). Pin a tag if you
  need stable `.day` parsing.
- Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md) — setup, the `just check` gate, and the
  pre-PR checklist.

## License

MIT. See [LICENSE](LICENSE).
