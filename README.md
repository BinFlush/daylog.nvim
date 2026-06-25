# daylog.nvim

Keep a plain-text log of your day in Neovim, and let it handle the timesheet math.

You note the time and what you're doing. Daylog reads the gap between each
timestamp as a duration and keeps a tidy summary underneath — always current, and
ready to copy into whatever system you report to.

## A quick look

```text
--- log ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```

Daylog keeps a summary right below it, refreshed as you type:

```text
--- summary q=15 d=dec ---
1.75h (+2m) planning
1.50h (+2m) PR review
0.50h (+3m) bugfixes on backend

--- totals ---
3.75h (+7m) workday
```

Repeated tasks are added together, and durations round to tidy buckets (15
minutes by default, or `q=1` for exact figures). The small `(+Nm)` on each row is
the rounding difference. The full format lives in `:help daylog.nvim`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "BinFlush/daylog.nvim",
  config = function()
    require("daylog").setup({
      daybook = { root = "~/daylog" }, -- where your dated files live
    })
  end,
}
```

Restart Neovim and run `:Lazy sync`. Everything is optional — see
[Configuration](#configuration) or `:help daylog-config`. Needs Neovim 0.8+ (and
`curl`, only if you use external [sources](#sources)).

Daylog sets no keymaps; map the commands you use. The examples use a `<leader>d`
prefix for the mnemonic, but it often collides with buffer maps — swap in whatever
prefix is free in your config:

```lua
-- global
vim.keymap.set("n", "<leader>dt", "<cmd>DaylogToday<cr>",   { desc = "Daylog: today" })
vim.keymap.set("n", "<leader>di", "<cmd>DaylogInsert<cr>",     { desc = "Daylog: insert time" })
vim.keymap.set("n", "<leader>dI", "<cmd>DaylogInsert!<cr>",    { desc = "Daylog: what to log" })
vim.keymap.set("n", "<leader>dw", "<cmd>DaylogDays monday..<cr>", { desc = "Daylog: week report" })
vim.keymap.set("n", "<leader>dc", "<cmd>DaylogCopy<cr>",    { desc = "Daylog: copy block" })
vim.keymap.set("n", "<leader>do", "<cmd>DaylogOrder<cr>",   { desc = "Daylog: order entries" })
vim.keymap.set("n", "<leader>df", "<cmd>DaylogRefresh<cr>", { desc = "Daylog: refresh summaries" })
vim.keymap.set("n", "]d",         "<cmd>DaylogNextDay<cr>", { desc = "Daylog: next day" })
vim.keymap.set("n", "[d",         "<cmd>DaylogPrevDay<cr>", { desc = "Daylog: prev day" })

-- with the cursor on a summary row or an entry
vim.keymap.set("n", "<leader>dr", "<cmd>DaylogRepeat<cr>",     { desc = "Daylog: repeat activity" })
vim.keymap.set("n", "<leader>dR", "<cmd>DaylogRename<cr>",     { desc = "Daylog: rename" })
vim.keymap.set("n", "<leader>dm", "<cmd>DaylogMap<cr>",        { desc = "Daylog: map to label" })
vim.keymap.set("n", "<leader>ds", "<cmd>DaylogSplit<cr>",      { desc = "Daylog: split activity" })
vim.keymap.set("n", "<leader>dl", "<cmd>DaylogLog<cr>",        { desc = "Daylog: toggle logged" })
vim.keymap.set("n", "<leader>d+", "<cmd>DaylogBalance +1<cr>", { desc = "Daylog: round up a step" })
vim.keymap.set("n", "<leader>d-", "<cmd>DaylogBalance -1<cr>", { desc = "Daylog: round down a step" })

-- visual mode: map every entry in the selection at once. The `:` inserts the `'<,'>`
-- range, so this must be ":DaylogMap<cr>" (a "<cmd>DaylogMap<cr>" map would pass no range).
vim.keymap.set("x", "<leader>dm", ":DaylogMap<cr>",           { desc = "Daylog: map selection" })
```

## A typical day

**Start the day — `:DaylogToday`.** Opens (or creates) today's file, stamps the
time, and drops you into insert mode. Type what you're starting on:

```text
--- log ---
09:00 planning
```

**Switch tasks — `:DaylogInsert`.** Stamps the current time on a new line for the
next task. You never type durations; the gap between two lines is how long the
first one took.

```text
--- log ---
09:00 planning
10:30 fixing the login bug
```

**Repeat something — `:DaylogRepeat`.** Put the cursor on an earlier entry (or on
its main summary row) and run it to copy that activity to now — handy for recurring
work like a standup or a client call.

**Stop the clock.** The last timestamp just closes the task before it, so end the
day with `:DaylogInsert` and type `done`.

**Mark what you've reported — `:DaylogLog`.** Once you've entered a block of time
into another system, put the cursor on its summary row and run it. Daylog marks
the underlying entries with `!L` so you can see what's already logged; run it again
to unmark.

**Review — `:DaylogDays`.** A read-only multi-day report — `:DaylogDays monday..`
for the week, `:DaylogDays 7` for the last seven days, or any date range. It stays
live as you edit the days it covers.

In short: open today, `Insert` / `Repeat` as you work, watch the live summary,
`Log` rows as you report them, and `Days` to review.

## Tags and locations

Add a reporting tag (`#tag`), a location (`@location`), or a per-block rounding
bucket (`q=`) in the header or on any entry:

```text
--- log #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

Tags and locations are sticky — an entry that omits one inherits the previous
value. The rest of the grammar (clearing with `#-` / `@-`, out-of-office `#ooo`,
the `!L` marker, the `=> alias` report label, the `d=hm` duration format) is in
`:help daylog-format`.

## Commands

| Command | Effect |
| --- | --- |
| `:DaylogToday [offset]` | Open today's daylog (creating it on first use); a nonzero offset only navigates |
| `:DaylogNextDay` / `:DaylogPrevDay [count]` | Step between days |
| `:DaylogInsert[!] [source]` | Stamp the current time; with a source name, pick one of its work items; with `!`, a unified fuzzy picker of your recent activities + every source's items (see [Sources](#sources)) |
| `:DaylogRepeat` | Repeat the activity under the cursor (an entry or its main summary row) at the current time |
| `:DaylogDays[!] {range}` | Open a multi-day report — a count, a date range, or named tokens like `monday..` (`!` for totals only) |
| `:DaylogLog` | Toggle the logged (`!L`) state of the summary row under the cursor |
| `:DaylogBalance [steps]` | Nudge the rounding of the summary row (or entry) under the cursor by ±N q-steps to land a residual (`0` clears) |
| `:DaylogRename [name\|source]` | Rename the entry's text, or a `#tag`/`@location`, under the cursor (an entry opens the unified picker; tag/location merge into an existing one). Not for activity summary rows — use `:DaylogMap` to relabel an activity for the report |
| `:[range]DaylogMap[!] [label\|source]` | Map the entry, every entry of a summary row, or every entry in a visual selection, to a report label (`=> alias`) — your text stays, the summary reads canonically; `!` clears it, or name a source to map onto a work item |
| `:DaylogSplit [w1 w2 …]` | Split the activity on the summary row under the cursor into weighted sub-activities (`foo (1)`, `foo (2)`, …), preserving its total time |
| `:DaylogCopy` | Append an editable copy of the active log to iterate on (the copy becomes the new active log) |
| `:DaylogOrder` | Rewrite the log in chronological order |
| `:DaylogRefresh` | Rebuild every summary to match its entries |
| `:DaylogSync [source]` | Refresh a source's cached work items |

The exact rules for each are in `:help daylog-commands`.

## Reports and live summaries

`:DaylogToday` and `:DaylogCopy` start a log with its summary attached, and
by default it stays live as you type (`auto_summary = "change"`). The same setting
keeps open `:DaylogDays` reports current. Prefer to refresh by
hand? Set `auto_summary = "off"` and use `:DaylogRefresh`. More in
`:help daylog-summaries`.

## Sources

Pull work items straight from a tracker into an entry. **Azure DevOps** is built
in: configure a named source, then `:DaylogInsert <name>` opens a picker and
inserts the chosen item as `{id} {title}`. Or `:DaylogInsert!` opens one fuzzy
list pooling every source's items together with your recent activities, ranked by
what you actually work on.

```lua
require("daylog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",
      project = "Platform",
      token = function() -- returns your PAT (see the setup guide below)
        return vim.trim(vim.fn.system({ "pass", "show", "daylog/ado-pat" }))
      end,
    },
  },
})
```

Picking is offline and instant — it reads a local cache, and only `:DaylogSync`
touches the network. With Telescope you get a fuzzy picker over the cache;
otherwise `vim.ui.select`, so fzf-lua / snacks / mini.pick work too. Live
as-you-type search of the whole tracker is opt-in — set `search = true` on the
source. The picker also leads with the items you've logged most recently and most
often (a Mozilla-style frecency over your daylogs).

- **Set up the token:** [docs/azure-devops.md](docs/azure-devops.md) covers creating
  the PAT, where to keep it, and troubleshooting.
- **All the options** — several projects at once, saved queries, custom insert
  templates: `:help daylog-sources`.
- **Your own tracker** (Jira, GitHub Issues, …): register a small table, see
  `:help daylog-custom-source`.

## Configuration

```lua
require("daylog").setup({
  defaults = { tag = "ClientA", location = "office", quantize_minutes = 15, duration_format = "dec" },
  daybook = { root = "~/daylog", directory = "%Y/%V" }, -- directory is an optional strftime template
  auto_summary = "change", -- change | idle | save | off
  auto_timezone = true, -- baseline the UTC offset and record DST/travel drift (off = manual only)
})
```

Everything is optional. `defaults` seed each new day's header; `daybook.root` is
where `:DaylogToday` and the reports look (files are always `YYYY-MM-DD.day`).
`auto_timezone` (on by default) records the UTC offset so a clock change while you
work — DST or travel — never skews a duration; `:help daylog-auto-timezone`. Full
reference: `:help daylog-config`.

## Documentation

- `:help daylog.nvim` — format, commands, and every option.
- `:checkhealth daylog` — verify your setup.
- [docs/azure-devops.md](docs/azure-devops.md) — set up the Azure DevOps source.
- [docs/architecture.md](docs/architecture.md) — internal design notes.

## Compatibility

`daylog.nvim` is pre-1.0, so syntax or behavior may still change — anything
breaking is called out in [CHANGELOG.md](CHANGELOG.md). The project keeps existing
`.day` files working where it can; pin a tagged release if you need that
guaranteed.

## Contributing

`just install` sets up the git hooks, and `just check` runs the full local gate
(format, lint, tests, health). See `:help daylog-development` or the `justfile`
for the rest.

## License

MIT. See [LICENSE](LICENSE).
