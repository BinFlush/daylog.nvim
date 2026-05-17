# justfile

default:
    just --list

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

smoke:
    nvim --headless -u NONE \
      "+set rtp+=." \
      "+lua require('worklog').setup()" \
      +qa

docs:
    nvim --headless -u NONE "+helptags doc" +qa

check:
    just format-check
    just test
    just smoke
