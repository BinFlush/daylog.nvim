return function(t)
  -- Example-based regeneration scenarios, each asserting the WHOLE regenerated document
  -- exactly (input -> output); trailing comments mark the line(s) each scenario turns on.
  -- The behavioural counterpart to refresh_summaries.lua (the edit-script contract) and
  -- regen_invariants.lua (the fuzzed properties). Ordered from the simplest single-blotter
  -- cases through summary-zone repair, banner reclaim, multi-blotter, and
  -- corrupted/missing-header recovery.
  local refresh_summaries = require("blotter.usecases.refresh_summaries")

  -- Apply refresh's edit script to a line list (the pure mirror of the buffer apply), in
  -- the order returned, so a test can compare the regenerated document to an exact expected.
  local function regen(lines)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line
    end
    for _, edit in ipairs(refresh_summaries.run(lines).edits) do
      local next_out = {}
      for i = 1, edit.start_index do
        next_out[#next_out + 1] = out[i]
      end
      for _, line in ipairs(edit.lines) do
        next_out[#next_out + 1] = line
      end
      for i = edit.end_index + 1, #out do
        next_out[#next_out + 1] = out[i]
      end
      out = next_out
    end
    return out
  end

  -- ===================== single-blotter basics =====================

  t.test("scenario: a fresh blotter gains a summary", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- summary created from the blots
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a single blot with no completed interval yields an empty summary", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday", -- no completed interval -> empty summary
      }
    )
  end)

  t.test("scenario: an already-current blotter regenerates to itself", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a", -- already canonical -> unchanged
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a flush body note is preserved", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "a flush note", -- flush body note
        "10:00 done",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "a flush note", -- kept in the body
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a blank-separated body note is preserved", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "a separated note", -- blank-separated body note
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "a separated note", -- kept in the body
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  -- ===================== summary-zone repair =====================

  t.test("scenario: a stale summary total is corrected", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "9.99h (+0m) a", -- stale total
        "",
        "--- totals ---",
        "9.99h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a", -- recomputed from the blots
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a one-blank separator is normalized to two", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "--- summary q=15 d=dec ---", -- preceded by ONE blank
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- now preceded by two
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a three-blank separator is normalized to two", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "",
        "--- summary q=15 d=dec ---", -- preceded by THREE blanks
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- now preceded by two
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a non-generated line inside the summary is regenerated away", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "ad-hoc note", -- prose inside the summary zone -> discarded
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: trailing prose below the summary is regenerated away", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "leftover thought", -- prose below the summary -> swept
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a duplicated summary is collapsed to one", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- duplicated (two copies)
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- summary q=15 d=dec ---", -- duplicated (two copies)
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- collapsed to one
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  -- ===================== banner reclaim =====================

  t.test("scenario: a deleted summary banner is restored", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "1.00h (+0m) a", -- banner line deleted; rows leaked out
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- banner restored
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a misspelled banner is reclaimed in place", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- sumary q=15 d=dec ---", -- misspelled banner
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- reclaimed
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a banner with appended junk is reclaimed", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec EDITED ---", -- appended junk
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- reclaimed
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a drifted banner q=/d= is rewritten to the header's", function()
    t.eq(
      regen({
        "--- blots q=15 ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=99 d=hm ---", -- q=/d= drifted from the header
        "1:00 (+0m) a",
        "",
        "--- totals ---",
        "1:00 (+0m) workday",
      }),
      {
        "--- blots q=15 ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---", -- rewritten to the header's q=15 d=dec
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  -- ===================== multi-blotter (valid) =====================

  t.test("scenario: two stacked blotters, each summarized with a two-blank gap", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "--- blots ---",
        "13:00 b", -- second blotter (no summary yet)
        "14:00 done",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "13:00 b", -- second blotter, summarized below
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: three stacked blotters are each summarized", function()
    t.eq(
      regen({
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "--- blots ---",
        "12:00 b", -- second blotter
        "13:00 done",
        "",
        "--- blots ---",
        "18:00 c", -- third blotter
        "19:00 done",
      }),
      {
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "12:00 b",
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a middle blotter with no summary gains one, neighbours untouched", function()
    t.eq(
      regen({
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "12:00 b", -- middle blotter has no summary
        "13:00 done",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "12:00 b",
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b", -- middle summary created
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  -- ===================== corrupted / missing header recovery =====================

  t.test("scenario: a corrupted keyword on the second header is recovered", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blts ---", -- second header: keyword corrupted
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "13:00 b", -- second blotter recovered + summarized
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a dropped dash on the second header is recovered, params read back", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "-- blots q=45 d=hm ---", -- second header: a dropped dash
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=45 d=hm ---",
        "0:45 (+15m) b",
        "",
        "--- totals ---",
        "0:45 (+15m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots q=45 d=hm ---", -- repaired; q=/d= read back
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=45 d=hm ---",
        "0:45 (+15m) b",
        "",
        "--- totals ---",
        "0:45 (+15m) workday",
      }
    )
  end)

  t.test("scenario: an obliterated header inherits the previous blotter's metadata", function()
    t.eq(
      regen({
        "--- blots #proj q=20 ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=20 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- tags ---",
        "1.00h (+0m) #proj",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "scratch reminder text", -- second header obliterated to prose
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=45 d=dec ---",
        "0.75h (+15m) b",
        "",
        "--- totals ---",
        "0.75h (+15m) workday",
      }),
      {
        "--- blots #proj q=20 ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=20 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- tags ---",
        "1.00h (+0m) #proj",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots #proj q=20 ---",
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=20 d=dec ---",
        "1.00h (+0m) b", -- recovered; q=20 inherited from blotter 1
        "",
        "--- tags ---",
        "1.00h (+0m) #proj",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a deleted second header line is synthesized above its blots", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "13:00 b", -- headerless blots (second header was deleted)
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b", -- header synthesized; summarized
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: a corrupted header keeps every option (#tag @loc utc d=hm)", function()
    t.eq(
      regen({
        "--- blots #proj @site utc+2 q=30 d=hm ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "1:00 (+0m) a",
        "",
        "--- tags ---",
        "1:00 (+0m) #proj",
        "",
        "--- locations ---",
        "1:00 (+0m) @site",
        "",
        "--- totals ---",
        "1:00 (+0m) workday",
        "",
        "",
        "--- blts #proj @site utc+2 q=30 d=hm ---", -- corrupted keyword, options intact
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "1:00 (+0m) b",
        "",
        "--- tags ---",
        "1:00 (+0m) #proj",
        "",
        "--- locations ---",
        "1:00 (+0m) @site",
        "",
        "--- totals ---",
        "1:00 (+0m) workday",
      }),
      {
        "--- blots #proj @site utc+2 q=30 d=hm ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "1:00 (+0m) a",
        "",
        "--- tags ---",
        "1:00 (+0m) #proj",
        "",
        "--- locations ---",
        "1:00 (+0m) @site",
        "",
        "--- totals ---",
        "1:00 (+0m) workday",
        "",
        "",
        "--- blots #proj @site utc+2 q=30 d=hm ---",
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "1:00 (+0m) b", -- recovered with every option
        "",
        "--- tags ---",
        "1:00 (+0m) #proj",
        "",
        "--- locations ---",
        "1:00 (+0m) @site",
        "",
        "--- totals ---",
        "1:00 (+0m) workday",
      }
    )
  end)

  t.test("scenario: only the corrupted middle blotter of three is repaired", function()
    t.eq(
      regen({
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blts ---", -- middle header corrupted
        "12:00 b",
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "12:00 b", -- middle recovered; 1st and 3rd untouched
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("scenario: two corrupted headers are recovered in one pass", function()
    t.eq(
      regen({
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blts ---", -- corrupted header
        "12:00 b",
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      {
        "--- blots ---",
        "08:00 a",
        "09:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "12:00 b",
        "13:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- blots ---",
        "18:00 c",
        "19:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) c",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  -- ===================== left untouched / no-ops =====================

  t.test("scenario: a --- notes --- block that contains blot-shaped lines is left alone", function()
    t.eq(
      regen({
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- notes ---", -- deliberate section, not a blots header
        "13:00 b",
        "14:00 done",
      }),
      {
        "--- blots ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- notes ---", -- left untouched (no blotter fabricated)
        "13:00 b",
        "14:00 done",
      }
    )
  end)

  t.test("scenario: a corrupted FIRST header is a structural no-op", function()
    t.eq(
      regen({
        "--- blts ---", -- corrupted FIRST header -> structural no-op
        "09:00 a",
        "10:00 done",
      }),
      {
        "--- blts ---",
        "09:00 a",
        "10:00 done",
      }
    )
  end)

  t.test("scenario: a document of bare timestamps invents no blotter", function()
    t.eq(
      regen({
        "09:00 a", -- no blotter header at all -> left alone
        "10:00 done",
      }),
      {
        "09:00 a",
        "10:00 done",
      }
    )
  end)
end
