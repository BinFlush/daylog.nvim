# worklog.nvim

Keep a plain-text log of your day in Neovim, and let it handle the timesheet math.

You note the time and what you're doing. worklog reads the gap between each
timestamp as a duration and keeps a tidy summary underneath — always current, and
ready to copy into whatever system you report to.

## A quick look

```text
--- worklog ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```

worklog keeps a summary right below it, refreshed as you type:

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
the rounding difference. The full format lives in `:help worklog.nvim`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "BinFlush/worklog.nvim",
  config = function()
    require("worklog").setup({
      journal = { root = "~/worklog" }, -- where your dated files live
    })
  end,
}
```

Restart Neovim and run `:Lazy sync`. Everything is optional — see
[Configuration](#configuration) or `:help worklog-config`. Needs Neovim 0.8+ (and
`curl`, only if you use external [sources](#sources)).

worklog sets no keymaps; map the commands you use, for example:

```lua
-- global
vim.keymap.set("n", "<leader>wt", "<cmd>WorklogToday<cr>",   { desc = "Worklog: today" })
vim.keymap.set("n", "<leader>wi", "<cmd>WorklogInsert<cr>",  { desc = "Worklog: insert time" })
vim.keymap.set("n", "<leader>wk", "<cmd>WorklogWeek<cr>",    { desc = "Worklog: week report" })
vim.keymap.set("n", "<leader>wd", "<cmd>WorklogDays<cr>",    { desc = "Worklog: days report" })
vim.keymap.set("n", "<leader>ww", "<cmd>WorklogCopy<cr>",    { desc = "Worklog: copy block" })
vim.keymap.set("n", "<leader>wo", "<cmd>WorklogOrder<cr>",   { desc = "Worklog: order entries" })
vim.keymap.set("n", "<leader>wf", "<cmd>WorklogRefresh<cr>", { desc = "Worklog: refresh summaries" })
vim.keymap.set("n", "]w",         "<cmd>WorklogNextDay<cr>", { desc = "Worklog: next day" })
vim.keymap.set("n", "[w",         "<cmd>WorklogPrevDay<cr>", { desc = "Worklog: prev day" })

-- with the cursor on a summary row or an entry
vim.keymap.set("n", "<leader>wr", "<cmd>WorklogRepeat<cr>",     { desc = "Worklog: repeat activity" })
vim.keymap.set("n", "<leader>wR", "<cmd>WorklogRename<cr>",     { desc = "Worklog: rename" })
vim.keymap.set("n", "<leader>wl", "<cmd>WorklogLog<cr>",        { desc = "Worklog: toggle logged" })
vim.keymap.set("n", "<leader>wb", "<cmd>WorklogBalance +1<cr>", { desc = "Worklog: round up a step" })
vim.keymap.set("n", "<leader>wB", "<cmd>WorklogBalance -1<cr>", { desc = "Worklog: round down a step" })
```

## A typical day

**Start the day — `:WorklogToday`.** Opens (or creates) today's file, stamps the
time, and drops you into insert mode. Type what you're starting on:

```text
--- worklog ---
09:00 planning
```

**Switch tasks — `:WorklogInsert`.** Stamps the current time on a new line for the
next task. You never type durations; the gap between two lines is how long the
first one took.

```text
--- worklog ---
09:00 planning
10:30 fixing the login bug
```

**Repeat something — `:WorklogRepeat`.** Put the cursor on an earlier entry (or on
its main summary row) and run it to copy that activity to now — handy for recurring
work like a standup or a client call.

**Stop the clock.** The last timestamp just closes the task before it, so end the
day with `:WorklogInsert` and type `done`.

**Mark what you've reported — `:WorklogLog`.** Once you've entered a block of time
into another system, put the cursor on its summary row and run it. worklog marks
the underlying entries with `!L` so you can see what's already logged; run it again
to unmark.

**Review — `:WorklogWeek`.** A read-only report of the whole week (`:WorklogDays 7`
for the last seven days). It stays live as you edit the days it covers.

In short: open today, `Insert` / `Repeat` as you work, watch the live summary,
`Log` rows as you report them, and `Week` to review.

## Tags and locations

Add a reporting tag (`#tag`), a location (`@location`), or a per-block rounding
bucket (`q=`) in the header or on any entry:

```text
--- worklog #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

Tags and locations are sticky — an entry that omits one inherits the previous
value. The rest of the grammar (clearing with `#-` / `@-`, out-of-office `#ooo`,
the `!L` marker, the `d=hm` duration format) is in `:help worklog-format`.

## Commands

| Command | Effect |
| --- | --- |
| `:WorklogToday [offset]` | Open today's journal (creating it on first use); a nonzero offset only navigates |
| `:WorklogNextDay` / `:WorklogPrevDay [count]` | Step between journal days |
| `:WorklogInsert [source]` | Stamp the current time; with a source name, pick a work item to insert (see [Sources](#sources)) |
| `:WorklogRepeat` | Repeat the activity under the cursor (an entry or its main summary row) at the current time |
| `:WorklogWeek[!]` / `:WorklogDays[!] {n}` | Open a week / last-N-days report (`!` for totals only) |
| `:WorklogLog` | Toggle the logged (`!L`) state of the summary row under the cursor |
| `:WorklogRename [name\|source]` | Rename (or merge) the activity, tag, or location of the summary row under the cursor; for an activity, name a [source](#sources) to replace it with a tracked work item |
| `:WorklogCopy` | Append a tidy, editable copy of the worklog |
| `:WorklogOrder` | Rewrite the worklog in chronological order |
| `:WorklogRefresh` | Rebuild every summary to match its entries |
| `:WorklogSync [source]` | Refresh a source's cached work items |

The exact rules for each are in `:help worklog-commands`.

## Reports and live summaries

`:WorklogToday` and `:WorklogCopy` start a worklog with its summary attached, and
by default it stays live as you type (`auto_summary = "change"`). The same setting
keeps open `:WorklogWeek` / `:WorklogDays` reports current. Prefer to refresh by
hand? Set `auto_summary = "off"` and use `:WorklogRefresh`. More in
`:help worklog-summaries`.

## Sources

Pull work items straight from a tracker into an entry. **Azure DevOps** is built
in: configure a named source, then `:WorklogInsert <name>` opens a picker and
inserts the chosen item as `{id} {title}`.

```lua
require("worklog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",
      project = "Platform",
      token = function() -- returns your PAT (see the setup guide below)
        return vim.trim(vim.fn.system({ "pass", "show", "worklog/ado-pat" }))
      end,
    },
  },
})
```

Picking is offline and instant — it reads a local cache, and only `:WorklogSync`
touches the network. With Telescope installed you can search the whole tracker as
you type; otherwise the picker is `vim.ui.select`, so fzf-lua / snacks / mini.pick
work too.

- **Set up the token:** [docs/azure-devops.md](docs/azure-devops.md) covers creating
  the PAT, where to keep it, and troubleshooting.
- **All the options** — several projects at once, saved queries, custom insert
  templates: `:help worklog-sources`.
- **Your own tracker** (Jira, GitHub Issues, …): register a small table, see
  `:help worklog-custom-source`.

## Configuration

```lua
require("worklog").setup({
  defaults = { tag = "ClientA", location = "office", quantize_minutes = 15, duration_format = "dec" },
  journal = { root = "~/timereg", directory = "%Y/%V" }, -- directory is an optional strftime template
  auto_summary = "change", -- change | idle | save | off
})
```

Everything is optional. `defaults` seed each new day's header; `journal.root` is
where `:WorklogToday` and the reports look (files are always `YYYY-MM-DD.wkl`). Full
reference: `:help worklog-config`.

## Documentation

- `:help worklog.nvim` — format, commands, and every option.
- `:checkhealth worklog` — verify your setup.
- [docs/azure-devops.md](docs/azure-devops.md) — set up the Azure DevOps source.
- [docs/architecture.md](docs/architecture.md) — internal design notes.

## Compatibility

`worklog.nvim` is pre-1.0, so syntax or behavior may still change — anything
breaking is called out in [CHANGELOG.md](CHANGELOG.md). The project keeps existing
`.wkl` files working where it can; pin a tagged release if you need that
guaranteed.

## Contributing

`just install` sets up the git hooks, and `just check` runs the full local gate
(format, lint, tests, health). See `:help worklog-development` or the `justfile`
for the rest.

## License

MIT. See [LICENSE](LICENSE).
