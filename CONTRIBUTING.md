# Contributing to daylog.nvim

Thanks for your interest in improving daylog.nvim. Bug reports, features, and documentation fixes are
all welcome. The project is small and has a deliberate design, so a little orientation goes a long way.

## Design

daylog keeps a **pure semantic core** (plain Lua over tables, no Neovim API) behind a **thin shell
layer** (the Neovim-facing glue). Read [`docs/architecture.md`](docs/architecture.md) before any
structural change — it is the source of truth for the pipeline (`source lines → syntax nodes →
semantic log → edit scripts`) and for where new logic belongs: in a pure module, with the shell kept a
thin adapter.

## Reporting a bug

Open a GitHub issue with:

- your Neovim version (`nvim --version`),
- a minimal `.day` file that reproduces the problem,
- the output of `:checkhealth daylog`.

## Development setup

You need **Neovim 0.8.0 or newer** and, for the checks, [`just`](https://github.com/casey/just),
[`stylua`](https://github.com/JohnnyMorganz/StyLua), and
[`luacheck`](https://github.com/lunarmodules/luacheck).

Run this once to install the git hooks:

```sh
just install
```

It points git at `.githooks/`; the pre-commit hook then runs the full gate (`just check`) before each
commit.

## The gate

One command has to pass:

```sh
just check
```

It is `just static-check` (stylua formatting + luacheck) plus `just nvim-check` (a help-tags check, the
test suite, and `:checkhealth daylog`). Handy sub-commands while you work:

- `just fmt` — apply formatting.
- `just test` — run the headless test suite (`tests/run.lua`).
- `just lint` — luacheck only.
- `just health` — `:checkhealth daylog`.

CI (`.github/workflows/check.yml`) runs the same `just check` across a matrix of Neovim versions, from
the **0.8.0 floor** through stable. Avoid APIs newer than 0.8.0 — or guard them with `pcall` so the
floor keeps working.

## Style

Style is enforced, not advisory: 2-space indent, 100 columns, double quotes (see `stylua.toml`);
luacheck runs as `lua51` with the `vim` global. Run `just fmt` before committing.

## Before you open a PR

- `just check` is green.
- New behaviour has tests. The harness is tiny — each file is a `return function(t) ... end` module
  using `t.test` / `t.eq` / `t.ok` and friends; add yours to the list in `tests/run.lua`.
- User-facing changes have a `## Unreleased` entry in [`CHANGELOG.md`](CHANGELOG.md).
- If you edited `doc/daylog.txt`, run `just helptags` and commit the updated `doc/tags`.
- If you changed derived output (summaries or rendering), update the `tests/compat/` fixtures
  deliberately and note it in `CHANGELOG.md` — daylog preserves valid `.day` files where practical.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md) code of conduct.
