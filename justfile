# justfile

default:
    just --list

install:
    git config --local core.hooksPath .githooks

format:
    stylua lua tests plugin ftplugin

fmt: format

format-check:
    stylua --check lua tests plugin ftplugin

test:
    # cq on failure so a red suite exits non-zero (a trailing +qa! would swallow it).
    nvim --headless -i NONE -u NONE \
      "+set rtp+=." \
      "+lua local ok, err = pcall(function() dofile('tests/run.lua') end); if ok then vim.cmd('qa!') else io.stderr:write(tostring(err) .. '\n'); vim.cmd('cq') end"

# Property-fuzz sweep of the summary footing invariant; the always-on `test`
# runs a fast fixed-seed sample of the same fuzz. Args (all optional):
#   mode    a synth mode (maximal|workday|billing) or "all"   [all]
#   rounds  logs per mode                                  [5000]
#   seed    master RNG seed, "random" to roll one, or "HEAD" [HEAD]
#           to derive it from the current commit hash.
# "HEAD" varies the corpus per commit (surfacing latent bugs) yet stays
# reproducible: same commit -> same seed, and the resolved seed is printed so a
# failure replays via `just fuzz <mode> <rounds> <seed>`.
# e.g. `just fuzz`, `just fuzz workday`, `just fuzz billing 20000 random`.
fuzz mode="all" rounds="5000" seed="HEAD":
    #!/usr/bin/env bash
    set -euo pipefail
    seed='{{seed}}'
    if [ "$seed" = "HEAD" ]; then
      hash=$(git rev-parse HEAD 2>/dev/null | head -c 8 || true)
      if [ -n "$hash" ]; then seed=$(printf '%d' "0x$hash"); else seed=1234567; fi
    fi
    DAYLOG_FUZZ_MODE='{{mode}}' DAYLOG_FUZZ_ROUNDS='{{rounds}}' DAYLOG_FUZZ_SEED="$seed" \
      nvim --headless -i NONE -u NONE \
        "+set rtp+=." \
        "+luafile tests/fuzz.lua"

# Dependency-free line coverage of lua/daylog via a debug hook: run the whole suite and print the
# uncovered code-looking lines per file. Slow (the hook makes the fuzz sweeps take minutes), so it is
# NOT part of `just check` -- it is a manual tool for finding untested branches.
coverage:
    nvim --headless -i NONE -u NONE \
      "+set rtp+=." \
      "+lua local c=dofile('tests/coverage.lua'); c.start(); pcall(function() dofile('tests/run.lua') end); c.report()" \
      "+qa!"

# Integration tests for the optional Telescope UI (lua/daylog/telescope.lua), driving REAL pickers via
# plenary busted -- the way Telescope tests itself. Needs telescope.nvim + plenary.nvim installed (lazy
# or site/pack; minimal_init discovers them). Standalone: the always-on `test`/`check` run under -u NONE
# with no Telescope, so this is not part of the gate; run it where Telescope is available.
test-telescope:
    nvim --headless --noplugin -u tests/integration/minimal_init.lua \
      -c "PlenaryBustedDirectory tests/integration/ { minimal_init = 'tests/integration/minimal_init.lua' }"

health:
    nvim --headless -u NONE \
      "+set rtp+=." \
      "+checkhealth daylog" \
      +qa

helptags:
    nvim --headless -u NONE "+helptags doc" +qa

lint:
    luacheck lua tests plugin ftplugin

static-check:
    just format-check
    just lint

# Verify doc/tags is up to date without modifying the working tree.
# We generate helptags in a temporary copy of doc/ and compare the result.
helptags-check:
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    cp -R doc "$tmp/doc"; \
    nvim --headless -u NONE "+helptags $tmp/doc" +qa; \
    diff -u doc/tags "$tmp/doc/tags"

nvim-check:
    just helptags-check
    just test
    just health

check:
    just static-check
    just nvim-check

release-check:
    just check

# Cut release vVERSION: verify the tree, rename CHANGELOG's `## Unreleased` section to
# the version and today's date, commit (gated by the pre-commit hook), and tag. Then run
# `git push origin main --follow-tags` to publish the GitHub release.
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{VERSION}}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION must be X.Y.Z (got '$version')" >&2; exit 1; }
    [ "$(git branch --show-current)" = "main" ] || { echo "error: not on the main branch" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "error: working tree is not clean" >&2; exit 1; }
    git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "error: tag v$version already exists" >&2; exit 1; }
    grep -q '^## Unreleased$' CHANGELOG.md || { echo "error: CHANGELOG.md has no '## Unreleased' section" >&2; exit 1; }
    sed -i "s/^## Unreleased$/## $version - $(date +%Y-%m-%d)/" CHANGELOG.md
    git add CHANGELOG.md
    git commit -m "Release $version"
    git tag -a "v$version" -m "v$version"
    printf '\nRelease %s committed and tagged v%s.\nPublish with:\n  git push origin main --follow-tags\n' "$version" "$version"
