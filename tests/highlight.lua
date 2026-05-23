return function(t)
  -- Contract test for syntax/worklog.vim. It guards against the highlighter
  -- drifting from the grammar that document.lua parses: every canonical token
  -- below must classify as the expected syntax group. When a new token is added
  -- to the parser, add it here too.

  local function group_at(lnum, col)
    return vim.fn.synIDattr(vim.fn.synID(lnum, col, 1), "name")
  end

  local function col_of(lnum, needle)
    local found = vim.fn.getline(lnum):find(needle, 1, true)
    assert(found, string.format("token %q not found on line %d", needle, lnum))
    return found
  end

  local function load_worklog_syntax(lines)
    vim.cmd("syntax enable")
    t.reset(lines)
    vim.bo.filetype = "worklog"
    vim.bo.syntax = "worklog"
  end

  t.test("syntax/worklog.vim classifies canonical tokens", function()
    load_worklog_syntax({
      "--- worklog #ClientA @office quantize=30 ---",
      "08:00 planning #ClientA @office",
      "10:00 meeting #ooo",
      "12:00 resume #- @-",
      "14:00 done !L",
      "--- summary quantized ---",
      "1.75h (+2m) planning",
      "a free-form note",
      "10:17 #Q1 features",
    })

    -- Worklog header and its contained metadata/option tokens.
    t.eq(group_at(1, 1), "WorklogHeader")
    t.eq(group_at(1, col_of(1, "#ClientA")), "WorklogTag")
    t.eq(group_at(1, col_of(1, "@office")), "WorklogLocation")
    t.eq(group_at(1, col_of(1, "quantize=30")), "WorklogOption")

    -- Entry timestamp and trailing sticky metadata.
    t.eq(group_at(2, 1), "WorklogTimestamp")
    t.eq(group_at(2, col_of(2, "#ClientA")), "WorklogTag")
    t.eq(group_at(2, col_of(2, "@office")), "WorklogLocation")

    -- #ooo is highlighted distinctly from a plain tag.
    t.eq(group_at(3, col_of(3, "#ooo")), "WorklogOoo")

    -- Clear tokens read as ordinary tag/location metadata.
    t.eq(group_at(4, col_of(4, "#-")), "WorklogTag")
    t.eq(group_at(4, col_of(4, "@-")), "WorklogLocation")

    -- Logged marker.
    t.eq(group_at(5, col_of(5, "!L")), "WorklogLogged")

    -- Generated section header (non-worklog) and quantized summary row.
    t.eq(group_at(6, 1), "WorklogBlockHeader")
    t.eq(group_at(7, 1), "WorklogDuration")
    t.eq(group_at(7, col_of(7, "(+2m)")), "WorklogQuantError")

    -- Free-form note line.
    t.eq(group_at(8, 1), "WorklogNote")

    -- A '#' that is not part of the trailing metadata run is plain text, never a
    -- tag, mirroring the parser's trailing-only metadata rule.
    t.eq(group_at(9, 1), "WorklogTimestamp")
    t.ok(group_at(9, col_of(9, "#Q1")) ~= "WorklogTag", "mid-text #Q1 must not highlight as a tag")
  end)
end
