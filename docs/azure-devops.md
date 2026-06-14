# Azure DevOps setup

This guide sets up the optional **Azure DevOps** work-item source so
`:WorklogInsert ADO` can pull a work item straight into your worklog.

> **You only need this for the Azure DevOps integration.** The core of
> `worklog.nvim` needs no Personal Access Token and no `curl` — skip this entirely
> if you don't use a tracker source.

## 1. Create a Personal Access Token (PAT)

1. In Azure DevOps, open **User settings** (the avatar, top-right) → **Personal
   access tokens**.
2. Click **New Token** and set:
   - **Organization** — the one you'll query (matches `organization` below).
   - **Name** — e.g. `worklog.nvim`.
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
pass insert worklog/ado-pat   # paste the PAT at the hidden prompt
```

```lua
token = function()
  local pat = vim.fn.system({ "pass", "show", "worklog/ado-pat" })
  if vim.v.shell_error ~= 0 then
    -- Store locked or failed: return nil so worklog reports a clean token error
    -- instead of handing gpg's stderr to Azure DevOps as if it were the token.
    return nil
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
export WORKLOG_ADO_PAT="<your-pat>"
```

```lua
token = function()
  return vim.env.WORKLOG_ADO_PAT
end,
```

Easiest, but the token sits in plaintext in your shell config and is inherited by
every process you launch. Acceptable for a low-scope, short-lived PAT; prefer one of
the others if you can.

### Middle ground: a `0600` file

```sh
install -m 600 /dev/null ~/.config/worklog/ado-pat
# then paste the PAT into the file with your editor (avoids shell history)
```

```lua
token = function()
  local lines = vim.fn.readfile(vim.fn.expand("~/.config/worklog/ado-pat"))
  return lines[1] and vim.trim(lines[1]) or nil
end,
```

Owner-only on disk and never exported into the environment; still plaintext at rest,
so keep it out of any tracked dotfiles repo.

## 3. Configure the source

```lua
require("worklog").setup({
  sources = {
    ADO = {
      type = "azure_devops",
      organization = "contoso",        -- dev.azure.com/<organization>
      project = "Platform",            -- .../<project>
      token = function()
        local pat = vim.fn.system({ "pass", "show", "worklog/ado-pat" })
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
      --   min_query = 3,                     -- chars before live search runs
    },
  },
})

vim.keymap.set("n", "<leader>wa", "<cmd>WorklogInsert ADO<cr>", { desc = "Worklog insert ADO item" })
```

By default the source lists work items **assigned to you, active, and recently
changed**. Point it at a saved query with `query_id`, or supply raw WIQL with
`query` (the two are mutually exclusive).

## 4. Verify

1. `:checkhealth worklog` — under **Sources**, confirms `curl` is on `PATH`, that the
   `ADO` source is configured, and whether its cache is populated.
2. `:WorklogSync ADO` — fetches the work-item cache over the network. This is the
   only step that uses `curl` and the token.
3. `:WorklogInsert ADO` — pick an item; it is inserted as `{id} {title}` at the
   current time. With Telescope installed you can type to search the whole tracker.

### Troubleshooting

- **`source token() did not return a non-empty string`** — your `token` function
  returned nothing. With `pass`, the gpg-agent is usually just locked: run
  `pass show worklog/ado-pat` once in a terminal to unlock it, then retry.
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
- worklog resolves the token only at sync time, never writes it to the cache, and
  hands it to `curl` through a private config file rather than the command line, so
  it isn't exposed in `ps` / `/proc/<pid>/cmdline`.

See `:help worklog-sources` for the full source reference and
`:help worklog-custom-source` to add your own tracker (Jira, GitHub Issues, …).
