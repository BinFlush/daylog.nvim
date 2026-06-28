# Azure DevOps setup

This guide sets up the optional **Azure DevOps** work-item source so
`:Daylog insert ADO` can pull a work item straight into your log.

> **You only need this for the Azure DevOps integration.** The core of
> `daylog.nvim` needs no Personal Access Token and no `curl` — skip this entirely
> if you don't use a tracker source.

## 1. Create a Personal Access Token (PAT)

1. In Azure DevOps, open **User settings** (the avatar, top-right) → **Personal
   access tokens**.
2. Click **New Token** and set:
   - **Organization** — the one you'll query (matches `organization` below).
   - **Name** — e.g. `daylog.nvim`.
   - **Expiration** — pick a finite window (e.g. 90 days) and rotate when it lapses.
   - **Scopes** — **Work Items → Read**. That is the only scope this plugin needs;
     don't grant more.
3. Click **Create**, then copy the token now — Azure DevOps shows it only once.

Your `organization` and `project` are the two path segments of your project URL:
`https://dev.azure.com/<organization>/<project>`.

## 2. Store the token

The `token` field is just a Lua function that returns the PAT as a string, so you
can use whatever secret store you like. A few options, most to least secure:

### Recommended: `pass` (GPG-encrypted)

[`pass`](https://www.passwordstore.org/) keeps the token encrypted at rest and out
of your environment.

```sh
pass insert daylog/ado-pat   # paste the PAT at the hidden prompt
```

```lua
token = function()
  local pat = vim.fn.system({ "pass", "show", "daylog/ado-pat" })
  if vim.v.shell_error ~= 0 then
    return nil -- store locked or unavailable; log will report a clean error
  end
  return vim.trim(pat)
end,
```

Any password manager or OS keychain works the same way — e.g. macOS
`security find-generic-password`, Linux `secret-tool lookup`, or Windows Credential
Manager via `powershell.exe`. Return the secret from the function however your tool
exposes it.

### Simple: an environment variable

```sh
# in ~/.bashrc, ~/.zshrc, etc.
export DAYLOG_ADO_PAT="<your-pat>"
```

```lua
token = function()
  return vim.env.DAYLOG_ADO_PAT
end,
```

Easiest, but the token sits in plaintext in your shell config and is inherited by
every process you launch. Acceptable for a low-scope, short-lived PAT; prefer one of
the others if you can.

### Middle ground: a `0600` file

```sh
install -m 600 /dev/null ~/.config/daydaylog/ado-pat
# then paste the PAT into the file with your editor (avoids shell history)
```

```lua
token = function()
  local lines = vim.fn.readfile(vim.fn.expand("~/.config/daydaylog/ado-pat"))
  return lines[1] and vim.trim(lines[1]) or nil
end,
```

Owner-only on disk and never exported into the environment; still plaintext at rest,
so keep it out of any tracked dotfiles repo.

## 3. Configure the source

```lua
require("daylog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",        -- dev.azure.com/<organization>
      project = "Platform",            -- .../<project>  (optional; omit for org-wide)
      token = function()
        local pat = vim.fn.system({ "pass", "show", "daylog/ado-pat" })
        if vim.v.shell_error ~= 0 then
          return nil
        end
        return vim.trim(pat)
      end,
      -- optional:
      --   query_id  = "<saved query GUID>",  -- run a saved ADO query
      --   query     = "<raw WIQL>",          -- or your own WIQL
      --   template  = "{id} {title}",        -- inserted activity text
      --   ttl       = 1800,                  -- cache lifetime, seconds
      --   search    = false,                 -- opt in to live tracker search
      --   min_query = 3,                     -- chars before live search runs
    },
  },
})

vim.keymap.set("n", "<leader>wa", "<cmd>Daylog insert ADO<cr>", { desc = "Daylog insert ADO item" })
```

By default the source lists work items that **involve you** — assigned to or created
by you — that are active and recently changed, **across your whole organization**. Set
`project` (above) to scope it to one project, or `projects` to a subset (see below). For a different scope, point
it at a saved query with `query_id` (which needs a `project`) or supply raw WIQL with
`query`. Live as-you-type search of the tracker is opt-in (`search = true`) and uses
the same scope, so it never surfaces another team's items.

### Several projects

To search a chosen subset of projects at once, replace `project` with a `projects`
list:

```lua
projects = { "Platform", "Data Platform Product Area" },
```

log then queries at **organization scope** and filters to those team projects,
so one search spans them; each result is labelled with its project, and `{project}`
is available in `template`. `projects` is mutually exclusive with `project`,
`query`, and `query_id`. A Work Items (Read) PAT can read every project in the
organization you have access to — unless your org enforces project-scoped tokens, in
which case make sure the PAT can reach each listed project.

The list is capped at 100 projects (one WIQL filters them all, so a very long list
would hit Azure DevOps' query-size limit); for larger sets use a saved `query_id` or
raw `query`.

## 4. Verify

1. `:checkhealth daylog` — under **Sources**, confirms `curl` is on `PATH`, that the
   `ADO` source is configured, and whether its cache is populated.
2. `:Daylog sync ADO` — fetches the work-item cache over the network. This is the
   only step that uses `curl` and the token.
3. `:Daylog insert ADO` — pick an item; it is inserted as `{id} {title}` at the
   current time. With Telescope installed you can type to search the whole tracker.

### Troubleshooting

- **`source token() did not return a non-empty string`** — your `token` function
  returned nothing. With `pass`, the gpg-agent is usually just locked: run
  `pass show daylog/ado-pat` once in a terminal to unlock it, then retry.
- **`ADO sync failed: HTTP 401`** (or another non-2xx) — the PAT is wrong, expired,
  or lacks **Work Items (Read)**. Re-mint it.
- **`curl is not available`** — install `curl`; it is only needed for syncing.
- **WSL** — `pass` works the same. A terminal (curses) gpg prompt can't draw over
  Neovim, so either unlock once in a terminal, or — on WSLg — use a GUI pinentry:
  `sudo apt-get install -y pinentry-qt`, then put `pinentry-program
  /usr/bin/pinentry-qt` in `~/.gnupg/gpg-agent.conf` and `gpgconf --kill gpg-agent`.

## Security notes

- Grant the **minimum scope** (Work Items: Read) and a **short expiry**; rotate when
  it lapses.
- log resolves the token only at sync time, never writes it to the cache, and
  hands it to `curl` through a private config file rather than the command line, so
  it isn't exposed in `ps` / `/proc/<pid>/cmdline`.

See `:help daylog-sources` for the full source reference and
`:help daylog-custom-source` to add your own tracker (Jira, GitHub Issues, …).
