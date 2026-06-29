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

Install `BinFlush/daylog.nvim` with any plugin manager — `:Daylog` works the moment it loads, no
`setup()` required. To use the dated-file workflow, point it at a folder once:

```lua
require("daylog").setup({ daybook = { root = "~/daylog" } })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), `opts` runs that for you:

```lua
{ "BinFlush/daylog.nvim", opts = { daybook = { root = "~/daylog" } } }
```

`daybook.root` — where your dated files live — is the only setting most people need; the rest is
optional (see [Configuration](#configuration) or `:help daylog-config`). Without it, Daylog still
highlights and edits any `.day` file. Needs Neovim 0.8+ (and `curl`, only for external
[sources](#sources)).

## Keymaps

Daylog binds nothing by default — and with `:Daylog <Tab>` completion you may not want any.
Otherwise, pick a tier.

**A ready-made set.** Opt into a sensible, buffer-local default:

```lua
require("daylog").setup({ keymaps = true })
```

In `.day` files: `]d` / `[d` step between days (count-aware), and a `<localleader>` cluster — `i`
insert, `I` what-to-log, `r` repeat, `n` new, `c` copy, `o` order, `l` toggle-logged, `R` refresh.
Pass `keymaps = { ["<lhs>"] = "<rhs>", ... }` to choose your own.

**Your own keys.** Every verb is both a `:Daylog <verb>` command and a `require("daylog").<verb>()`
function — bind either form to any key (the keys here are just examples; swap in your own):

```lua
vim.keymap.set("n", "<leader>dt", "<Cmd>Daylog today<CR>")                          -- open today
vim.keymap.set("n", "]d", function() require("daylog").next_day(vim.v.count1) end)  -- 3]d -> 3 days on
vim.keymap.set("n", "<leader>dw", "<Cmd>Daylog report monday..<CR>")               -- this week's report
vim.keymap.set("n", "<leader>dm", function() require("daylog").map({}) end)         -- map to a report label
```

Use the command form for simple actions; use the function form when you want a count
(`next_day(vim.v.count1)`) or an argument. The verbs are listed under [Commands](#commands) (and
`:help daylog-keymaps` / `:help daylog-lua`). A visual-range `map` needs the command form, so the
`'<,'>` range comes through:

```lua
vim.keymap.set("x", "<leader>dm", ":Daylog map<cr>") -- relabel every entry or summary row in the selection
```

## A typical day

**Start the day — `:Daylog today`.** Opens (or creates) today's file, stamps the
time, and drops you into insert mode. Type what you're starting on:

```text
--- log ---
09:00 planning
```

**Switch tasks — `:Daylog insert`.** Stamps the current time on a new line for the
next task. You never type durations; the gap between two lines is how long the
first one took.

```text
--- log ---
09:00 planning
10:30 fixing the login bug
```

**Repeat something — `:Daylog repeat`.** Put the cursor on an earlier entry (or on
its main summary row) and run it to copy that activity to now — handy for recurring
work like a standup or a client call.

**Stop the clock.** The last timestamp just closes the task before it, so end the
day with `:Daylog insert` and type `done`.

**Mark what you've reported — `:Daylog log`.** Once you've entered a block of time
into another system, put the cursor on its summary row and run it. Daylog marks
the underlying entries with `!L` so you can see what's already logged; run it again
to unmark.

**Review — `:Daylog report`.** A read-only multi-day report — `:Daylog report monday..`
for the week, `:Daylog report 7` for the last seven days, or any date range. It stays
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
| `:Daylog` / `:Daylog today` | Open today's daylog, creating and stamping it on first use |
| `:Daylog day [when]` | Open/create a specific day (no time stamp) — `monday`, `-1`, `+2`, `2026-05-10` |
| `:Daylog next` / `:Daylog prev [count]` | Step between days |
| `:Daylog insert[!] [source]` | Stamp the current time; with a source name, pick one of its work items; with `!`, a unified fuzzy picker of your recent activities + every source's items (see [Sources](#sources)) |
| `:Daylog repeat` | Repeat the activity under the cursor (an entry or its main summary row) at the current time |
| `:Daylog report[!] {range}` | Open a multi-day report — a count, a date range, or named tokens like `monday..` (`!` for totals only) |
| `:Daylog log` | Toggle the logged (`!L`) state of the summary row under the cursor |
| `:Daylog balance [steps]` | Nudge the rounding of the summary row (or entry) under the cursor by ±N q-steps to land a residual (`0` clears) |
| `:Daylog rename [name\|source]` | Rename the entry's text, or a `#tag`/`@location`, under the cursor (an entry opens the unified picker; tag/location merge into an existing one). Not for activity summary rows — use `:Daylog map` to relabel an activity for the report |
| `:[range]Daylog[!] map [label\|source]` | Map the entry, every entry of a summary row, or every entry and summary row in a visual selection, to a report label (`=> alias`) — your text stays, the summary reads canonically; `!` clears it, or name a source to map onto a work item |
| `:Daylog split [w1 w2 …]` | Split the activity on the summary row under the cursor into weighted sub-activities (`foo (1)`, `foo (2)`, …), preserving its total time |
| `:Daylog copy` | Append an editable copy of the active log to iterate on (the copy becomes the new active log) |
| `:Daylog order` | Rewrite the log in chronological order |
| `:Daylog refresh` | Rebuild every summary to match its entries |
| `:Daylog sync [source]` | Refresh a source's cached work items |

The exact rules for each are in `:help daylog-commands`.

## Reports and live summaries

`:Daylog today` and `:Daylog copy` start a log with its summary attached, and
by default it stays live as you type (`auto_summary = "change"`). The same setting
keeps open `:Daylog report` reports current. Prefer to refresh by
hand? Set `auto_summary = "off"` and use `:Daylog refresh`. More in
`:help daylog-summaries`.

## Sources

Pull work items straight from a tracker into an entry. **Azure DevOps** is built
in: configure a named source, then `:Daylog insert <name>` opens a picker and
inserts the chosen item as `{id} {title}`. Or `:Daylog! insert` opens one fuzzy
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

Picking is offline and instant — it reads a local cache, and only `:Daylog sync`
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
where `:Daylog today` and the reports look (files are always `YYYY-MM-DD.day`).
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
