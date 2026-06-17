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
    nvim --headless -i NONE -u NONE \
      "+set rtp+=." \
      "+lua dofile('tests/run.lua')" \
      +qa!

# Property-fuzz sweep of the summary footing invariant; the always-on `test`
# runs a fast fixed-seed sample of the same fuzz. Args (all optional):
#   mode    a synth mode (maximal|workday|billing) or "all"   [all]
#   rounds  worklogs per mode                                  [5000]
#   seed    master RNG seed, or "random" to roll one (printed) [1234567]
# e.g. `just fuzz`, `just fuzz workday`, `just fuzz billing 20000 random`.
fuzz mode="all" rounds="5000" seed="1234567":
    WORKLOG_FUZZ_MODE={{mode}} \
      WORKLOG_FUZZ_ROUNDS={{rounds}} \
      WORKLOG_FUZZ_SEED={{seed}} \
      nvim --headless -i NONE -u NONE \
        "+set rtp+=." \
        "+luafile tests/fuzz.lua"

health:
    nvim --headless -u NONE \
      "+set rtp+=." \
      "+checkhealth worklog" \
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
