# blotter.nvim

Keep a plain-text log of your day in Neovim, and let it handle the timesheet math.

You note the time and what you're doing. blotter reads the gap between each
timestamp as a duration and keeps a tidy summary underneath — always current, and
ready to copy into whatever system you report to.

## A quick look

```text
--- blots ---
08:10 planning
08:47 bugfixes on backend
09:02 planning
10:12 bugfixes on backend
10:30 PR review
12:02 done
```

blotter keeps a summary right below it, refreshed as you type:

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
the rounding difference. The full format lives in `:help blotter.nvim`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "BinFlush/blotter.nvim",
  config = function()
    require("blotter").setup({
      journal = { root = "~/blotter" }, -- where your dated files live
    })
  end,
}
```

Restart Neovim and run `:Lazy sync`. Everything is optional — see
[Configuration](#configuration) or `:help blotter-config`. Needs Neovim 0.8+ (and
`curl`, only if you use external [sources](#sources)).

blotter sets no keymaps; map the commands you use, for example:

```lua
-- global
vim.keymap.set("n", "<leader>wt", "<cmd>BlotterToday<cr>",   { desc = "Blotter: today" })
vim.keymap.set("n", "<leader>wi", "<cmd>BlotInsert<cr>",  { desc = "Blotter: insert time" })
vim.keymap.set("n", "<leader>wk", "<cmd>BlotterWeek<cr>",    { desc = "Blotter: week report" })
vim.keymap.set("n", "<leader>wd", "<cmd>BlotterDays<cr>",    { desc = "Blotter: days report" })
vim.keymap.set("n", "<leader>ww", "<cmd>BlotterCopy<cr>",    { desc = "Blotter: copy block" })
vim.keymap.set("n", "<leader>wo", "<cmd>BlotterOrder<cr>",   { desc = "Blotter: order blots" })
vim.keymap.set("n", "<leader>wf", "<cmd>BlotterRefresh<cr>", { desc = "Blotter: refresh summaries" })
vim.keymap.set("n", "]w",         "<cmd>BlotterNextDay<cr>", { desc = "Blotter: next day" })
vim.keymap.set("n", "[w",         "<cmd>BlotterPrevDay<cr>", { desc = "Blotter: prev day" })

-- with the cursor on a summary row or an blot
vim.keymap.set("n", "<leader>wr", "<cmd>BlotRepeat<cr>",     { desc = "Blotter: repeat activity" })
vim.keymap.set("n", "<leader>wR", "<cmd>BlotRename<cr>",     { desc = "Blotter: rename" })
vim.keymap.set("n", "<leader>wl", "<cmd>BlotLog<cr>",        { desc = "Blotter: toggle logged" })
vim.keymap.set("n", "<leader>wb", "<cmd>BlotBalance +1<cr>", { desc = "Blotter: round up a step" })
vim.keymap.set("n", "<leader>wB", "<cmd>BlotBalance -1<cr>", { desc = "Blotter: round down a step" })
```

## A typical day

**Start the day — `:BlotterToday`.** Opens (or creates) today's file, stamps the
time, and drops you into insert mode. Type what you're starting on:

```text
--- blots ---
09:00 planning
```

**Switch tasks — `:BlotInsert`.** Stamps the current time on a new line for the
next task. You never type durations; the gap between two lines is how long the
first one took.

```text
--- blots ---
09:00 planning
10:30 fixing the login bug
```

**Repeat something — `:BlotRepeat`.** Put the cursor on an earlier blot (or on
its main summary row) and run it to copy that activity to now — handy for recurring
work like a standup or a client call.

**Stop the clock.** The last timestamp just closes the task before it, so end the
day with `:BlotInsert` and type `done`.

**Mark what you've reported — `:BlotLog`.** Once you've entered a block of time
into another system, put the cursor on its summary row and run it. blotter marks
the underlying blots with `!L` so you can see what's already logged; run it again
to unmark.

**Review — `:BlotterWeek`.** A read-only report of the whole week (`:BlotterDays 7`
for the last seven days). It stays live as you edit the days it covers.

In short: open today, `Insert` / `Repeat` as you work, watch the live summary,
`Log` rows as you report them, and `Week` to review.

## Tags and locations

Add a reporting tag (`#tag`), a location (`@location`), or a per-block rounding
bucket (`q=`) in the header or on any blot:

```text
--- blots #ClientA @office q=30 ---
08:00 planning
10:00 implementation @home
13:00 internal meeting #internal
14:00 client followup #ClientA @client
17:00 done
```

Tags and locations are sticky — an blot that omits one inherits the previous
value. The rest of the grammar (clearing with `#-` / `@-`, out-of-office `#ooo`,
the `!L` marker, the `d=hm` duration format) is in `:help blotter-format`.

## Commands

| Command | Effect |
| --- | --- |
| `:BlotterToday [offset]` | Open today's journal (creating it on first use); a nonzero offset only navigates |
| `:BlotterNextDay` / `:BlotterPrevDay [count]` | Step between journal days |
| `:BlotInsert [source]` | Stamp the current time; with a source name, pick a work item to insert (see [Sources](#sources)) |
| `:BlotRepeat` | Repeat the activity under the cursor (an blot or its main summary row) at the current time |
| `:BlotterWeek[!]` / `:BlotterDays[!] {n}` | Open a week / last-N-days report (`!` for totals only) |
| `:BlotLog` | Toggle the logged (`!L`) state of the summary row under the cursor |
| `:BlotRename [name\|source]` | Rename (or merge) the activity, tag, or location of the summary row under the cursor; for an activity, name a [source](#sources) to replace it with a tracked work item |
| `:BlotterCopy` | Append a tidy, editable copy of the blotter |
| `:BlotterOrder` | Rewrite the blotter in chronological order |
| `:BlotterRefresh` | Rebuild every summary to match its blots |
| `:BlotterSync [source]` | Refresh a source's cached work items |

The exact rules for each are in `:help blotter-commands`.

## Reports and live summaries

`:BlotterToday` and `:BlotterCopy` start a blotter with its summary attached, and
by default it stays live as you type (`auto_summary = "change"`). The same setting
keeps open `:BlotterWeek` / `:BlotterDays` reports current. Prefer to refresh by
hand? Set `auto_summary = "off"` and use `:BlotterRefresh`. More in
`:help blotter-summaries`.

## Sources

Pull work items straight from a tracker into an blot. **Azure DevOps** is built
in: configure a named source, then `:BlotInsert <name>` opens a picker and
inserts the chosen item as `{id} {title}`.

```lua
require("blotter").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",
      project = "Platform",
      token = function() -- returns your PAT (see the setup guide below)
        return vim.trim(vim.fn.system({ "pass", "show", "blotter/ado-pat" }))
      end,
    },
  },
})
```

Picking is offline and instant — it reads a local cache, and only `:BlotterSync`
touches the network. With Telescope installed you can search the whole tracker as
you type; otherwise the picker is `vim.ui.select`, so fzf-lua / snacks / mini.pick
work too.

- **Set up the token:** [docs/azure-devops.md](docs/azure-devops.md) covers creating
  the PAT, where to keep it, and troubleshooting.
- **All the options** — several projects at once, saved queries, custom insert
  templates: `:help blotter-sources`.
- **Your own tracker** (Jira, GitHub Issues, …): register a small table, see
  `:help blotter-custom-source`.

## Configuration

```lua
require("blotter").setup({
  defaults = { tag = "ClientA", location = "office", quantize_minutes = 15, duration_format = "dec" },
  journal = { root = "~/timereg", directory = "%Y/%V" }, -- directory is an optional strftime template
  auto_summary = "change", -- change | idle | save | off
})
```

Everything is optional. `defaults` seed each new day's header; `journal.root` is
where `:BlotterToday` and the reports look (files are always `YYYY-MM-DD.blot`). Full
reference: `:help blotter-config`.

## Documentation

- `:help blotter.nvim` — format, commands, and every option.
- `:checkhealth blotter` — verify your setup.
- [docs/azure-devops.md](docs/azure-devops.md) — set up the Azure DevOps source.
- [docs/architecture.md](docs/architecture.md) — internal design notes.

## Compatibility

`blotter.nvim` is pre-1.0, so syntax or behavior may still change — anything
breaking is called out in [CHANGELOG.md](CHANGELOG.md). The project keeps existing
`.blot` files working where it can; pin a tagged release if you need that
guaranteed.

## Contributing

`just install` sets up the git hooks, and `just check` runs the full local gate
(format, lint, tests, health). See `:help blotter-development` or the `justfile`
for the rest.

## License

MIT. See [LICENSE](LICENSE).
