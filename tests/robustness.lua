return function(t)
  local cwd = vim.fn.getcwd()
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/log_synth.lua")
  local document = require("daylog.document")
  local analyze = require("daylog.analyze")

  -- The parser and analyzer are only ever fed valid or hand-written input elsewhere. On hostile input
  -- they must degrade gracefully -- never raise a Lua error, and classify every line into a node --
  -- so a pasted/corrupt file surfaces as diagnostics, not a stack trace.

  local function random_line(rng, maxlen)
    local chars = {}
    for i = 1, rng:int(0, maxlen) do
      chars[i] = string.char(rng:int(1, 255))
    end
    return table.concat(chars)
  end

  local function mutate(rng, lines)
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = l
    end
    local idx = rng:int(1, math.max(1, #out))
    local kind = rng:int(1, 8)
    if kind == 1 and #(out[idx] or "") > 0 then -- flip a byte
      local l, p = out[idx], rng:int(1, #out[idx])
      out[idx] = l:sub(1, p - 1) .. string.char(rng:int(1, 255)) .. l:sub(p + 1)
    elseif kind == 2 and #(out[idx] or "") > 0 then -- drop a byte
      local l, p = out[idx], rng:int(1, #out[idx])
      out[idx] = l:sub(1, p - 1) .. l:sub(p + 1)
    elseif kind == 3 then -- truncate
      out[idx] = (out[idx] or ""):sub(1, rng:int(0, #(out[idx] or "")))
    elseif kind == 4 then -- splice garbage
      table.insert(out, idx, random_line(rng, 40))
    elseif kind == 5 then -- blank a line
      out[idx] = ""
    elseif kind == 6 then -- duplicate a line
      table.insert(out, idx, out[idx] or "")
    elseif kind == 7 then -- a stray token line
      table.insert(
        out,
        idx,
        rng:choice({ "--- ---", "!S[", "]]}}", "08:00 !!!!", "#", "@", "=>", "round-9" })
      )
    else -- prepend junk
      out[idx] = random_line(rng, 8) .. (out[idx] or "")
    end
    return out
  end

  -- A printable, bounded view of an input for a failure report (raw bytes would mangle the terminal).
  local function describe(lines)
    local shown = {}
    for i = 1, math.min(#lines, 8) do
      shown[i] = string.format("%q", lines[i]:sub(1, 80))
    end
    return table.concat(shown, "\n")
  end

  local function check(lines)
    local ok, doc = pcall(document.parse, lines)
    if not ok then
      return "document.parse raised: " .. tostring(doc)
    end
    if type(doc) ~= "table" or type(doc.nodes) ~= "table" then
      return "document.parse returned no nodes table"
    end
    if #doc.nodes ~= #lines then
      return string.format("classified %d nodes for %d lines", #doc.nodes, #lines)
    end
    local ok2, an = pcall(analyze.analyze, doc)
    if not ok2 then
      return "analyze.analyze raised: " .. tostring(an)
    end
    if type(an) ~= "table" or type(an.diagnostics) ~= "table" then
      return "analyze returned no diagnostics list"
    end
    return nil
  end

  t.test("parse + analyze never raise and classify every line on hostile input (fuzz)", function()
    local master = Rng.new(20260710)
    local function fail(err, lines)
      error(err .. "\n--- input ---\n" .. describe(lines), 0)
    end

    -- Mutated valid logs: 1..5 random edits to a synth log.
    for _, mode in ipairs(synth.MODES) do
      for _ = 1, 250 do
        local rng = Rng.new(master:int(1, 2147483646))
        local lines = synth.generate(Rng.new(master:int(1, 2147483646)), mode).lines
        for _ = 1, rng:int(1, 5) do
          lines = mutate(rng, lines)
        end
        local err = check(lines)
        if err then
          fail(err, lines)
        end
      end
    end

    -- Fully random line-sets, including embedded control/high bytes.
    for _ = 1, 500 do
      local rng = Rng.new(master:int(1, 2147483646))
      local lines = {}
      for i = 1, rng:int(0, 12) do
        lines[i] = random_line(rng, 60)
      end
      local err = check(lines)
      if err then
        fail(err, lines)
      end
    end

    -- Hand-crafted pathological cases.
    local nasty = {
      { string.rep("08:00 x ", 500) },
      { "--- log ---", string.rep("a", 5000) },
      { "!S[", "!T]", "]]}}{{", "08:00 =>=>=>", "  --- summary q= d= ---  " },
      { "\1\2\3", "24:00", "99:99 x", "08:00 #-#-#- @-@- !X!X", "--- log ---", "" },
    }
    for _, lines in ipairs(nasty) do
      local err = check(lines)
      if err then
        fail(err, lines)
      end
    end
  end)
end
