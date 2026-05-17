# justfile

default:
    just --list

install:
    git config --local core.hooksPath .githooks

format:
    stylua lua tests plugin

fmt: format

format-check:
    stylua --check lua tests plugin

test:
    nvim --headless -i NONE -u NONE \
      "+set rtp+=." \
      "+lua dofile('tests/run.lua')" \
      +qa!

health:
    nvim --headless -u NONE \
      "+set rtp+=." \
      "+checkhealth worklog" \
      +qa

helptags:
    nvim --headless -u NONE "+helptags doc" +qa

lint:
    luacheck lua tests plugin

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
