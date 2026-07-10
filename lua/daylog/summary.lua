local projection = require("daylog.projection")
local quantize = require("daylog.quantize")
local syntax = require("daylog.syntax")

local M = {}

-- Semantic reporting for log blocks: interval derivation, report sections, sorting, logged totals. PURE.
-- (Grouping engine lives in projection.lua, rounding arithmetic in quantize.lua.)

-- The rounding bucket for a block, defaulting a nil OR non-positive quantize. Guarding <= 0 (not just
-- nil) keeps a direct call with q=0 from dividing by zero -- 0 is truthy in Lua, so `q or DEFAULT`
-- would pass it straight through into the quantizer.
local function bucket_of(quantize_minutes)
  return (quantize_minutes and quantize_minutes > 0) and quantize_minutes
    or syntax.DEFAULT_QUANTIZE_MINUTES
end

-- The text an entry contributes to the summary: its alias when set, else its description.
-- Every grouping/display and the frecency ranker key on this, so a bare and a mapped entry
-- reporting as the same label rank as one activity.
function M.entry_summary_text(e)
  return (e.alias ~= nil and e.alias ~= "") and e.alias or e.text
end

-- A blank entry (bare timestamp, no activity text) marks uncounted time: excluded from every report,
-- never a map/rename target, carrying no metadata. PURE.
function M.is_blank_entry(entry)
  return entry.text == nil or entry.text == ""
end

local function build_intervals(entries)
  local intervals = {}

  for i = 1, #entries - 1 do
    local current = entries[i]

    -- A blank entry starts uncounted time; skip its interval so it lands in no report.
    if not M.is_blank_entry(current) then
      local next_entry = entries[i + 1]

      -- Durations are effective UTC (`local - offset`), so an interval spanning a clock move (timezone
      -- crossing or DST flip) is its true length; `start`/`stop` stay raw local clock (display only).
      local current_effective = current.minutes - (current.offset or 0)
      local next_effective = next_entry.minutes - (next_entry.offset or 0)

      -- Scalar logged state is the summary (`s`) level: present=logged, a number is the frozen value,
      -- `true` is a bare (unfrozen) marker.
      local logged_s = current.logged and current.logged.s

      table.insert(intervals, {
        start = current.minutes,
        stop = next_entry.minutes,
        duration = next_effective - current_effective,
        text = M.entry_summary_text(current),
        tag = current.tag,
        location = current.location,
        logged = logged_s ~= nil and true or nil,
        nudge = current.nudge,
        -- Every interval of one fine-grained row carries the same frozen value, so the fold copies it
        -- through, never sums it; a bare marker freezes nothing (stays nil, rounds live).
        logged_minutes = syntax.committed_minutes(logged_s),
        -- Whole per-level logged table, so tag/location sections split by their own level; `logged` /
        -- `logged_minutes` above are the summary (`s`) slice.
        logged_by_level = current.logged,
        -- Name-set keys (flat strings, "" when unnamed) split each level's cell at its own level; the
        -- parallel display lists (nil when unnamed) ride along for rendering the marker.
        s_names_key = syntax.names_key(current.logged and current.logged.s),
        t_names_key = syntax.names_key(current.logged and current.logged.t),
        l_names_key = syntax.names_key(current.logged and current.logged.l),
        w_names_key = syntax.names_key(current.logged and current.logged.w),
        s_names = current.logged and current.logged.s and current.logged.s.names or nil,
        t_names = current.logged and current.logged.t and current.logged.t.names or nil,
        l_names = current.logged and current.logged.l and current.logged.l.names or nil,
        w_names = current.logged and current.logged.w and current.logged.w.names or nil,
        source_entry_row = current.row,
      })
    end
  end

  return intervals
end

-- Exported for the time bar, which lays out the raw (real-duration) intervals directly.
M.build_intervals = build_intervals

-- The closing entry starts no interval, so its row is in no `source_entry_rows`; return it when it
-- WOULD group into `item` (same resolved text/tag/logged), so identity edits (:Daylog map / rename)
-- can reach a same-activity entry that currently closes the log. Returns nil when it does not match.
function M.closing_entry_row_for(entries, item)
  local last = entries[#entries]
  if not last then
    return nil
  end

  if
    M.entry_summary_text(last) == item.text
    and last.tag == item.tag
    and (last.logged and last.logged.s ~= nil and true or nil) == item.logged
  then
    return last.row
  end

  return nil
end

-- The cell an interval/granule belongs to at each level: activity (s), tag (t), location (l), or the
-- whole day (`workday`, w).
local function cell_key(row, level)
  if level == "t" then
    return (row.tag or "\0notag") .. "\0" .. (row.t_names_key or "")
  elseif level == "l" then
    return (row.location or "\0noloc") .. "\0" .. (row.l_names_key or "")
  elseif level == "w" then
    return "workday" .. "\0" .. (row.w_names_key or "")
  end
  return table.concat({ row.text or "", row.tag or "", row.s_names_key or "" }, "\0")
end

-- Group intervals into granules, the finest cell every partition coarsens: (text, tag, location).
-- Each carries real duration, its shared nudge (folded by "max"), the per-level committed table, and
-- source provenance.
local function build_granules(intervals)
  return projection.project_rows(
    intervals,
    { "text", "tag", "location", "s_names_key", "t_names_key", "l_names_key", "w_names_key" },
    {
      "text",
      "tag",
      "location",
      "logged_by_level",
      "s_names_key",
      "t_names_key",
      "l_names_key",
      "w_names_key",
      "s_names",
      "t_names",
      "l_names",
      "w_names",
    },
    true,
    "max"
  )
end

-- The committed value of each cell at `level`, summed across the cell's distinct commitment sub-scopes.
-- An `!S` commitment is frozen per (activity, location), so a location-spanning activity carries
-- several `!S` values that must be SUMMED, never last-wins; `!T`/`!L`/`!W` are one value per cell.
local function committed_by_cell(intervals, level, cell_key_fn)
  local scopes = {}
  for _, interval in ipairs(intervals) do
    local marker = interval.logged_by_level and interval.logged_by_level[level]
    local value = syntax.committed_minutes(marker)
    if value ~= nil then
      local cell = cell_key_fn(interval)
      local scope = level == "s"
          and (M.activity_identity_key(interval) .. "\0" .. (interval.s_names_key or ""))
        or cell
      scopes[cell] = scopes[cell] or {}
      scopes[cell][scope] = value
    end
  end

  local totals = {}
  for cell, by_scope in pairs(scopes) do
    local sum = 0
    for _, value in pairs(by_scope) do
      sum = sum + value
    end
    totals[cell] = sum
  end
  return totals
end

-- Honest largest-remainder quantization of the granules, then SURPLUS inflation: a committed cell whose
-- commitment exceeds its honest rounded total raises its granules to the committed value; a commitment
-- at or below stays honest (the split is a display concern), so every partition still foots. Inflation
-- scope: `!S` per (activity, location) granule, `!T`/`!L`/`!W` one value over a cell's granules.
local function quantize_granules(granules, intervals, bucket_minutes)
  local unrounded_total = 0
  for _, g in ipairs(granules) do
    unrounded_total = unrounded_total + (g.unrounded_duration or g.duration)
  end
  local honest = quantize.quantize_rows(
    granules,
    bucket_minutes,
    quantize.round_to_nearest_bucket(unrounded_total, bucket_minutes)
  )

  -- Collect only OVER-committed cells; their surplus must inflate and propagate. Index order is
  -- preserved from `granules`, so member lists index straight into constrained_quantize's copy.
  local commitments = {}
  -- Granules whose value an over-commitment dictates: their own round±N balance is inert (the inflation
  -- overrides it), so its marker must render nowhere -- matching the committed main row, which already
  -- suppresses it. Without this the tag/location/workday sections leak a stray `round±N`.
  local overcommitted = {}
  for _, level in ipairs({ "s", "t", "l", "w" }) do
    local key_fn = level == "s"
        and function(row)
          return M.activity_identity_key(row) .. "\0" .. (row.s_names_key or "")
        end
      or function(row)
        return cell_key(row, level)
      end
    local committed = committed_by_cell(intervals, level, key_fn)

    local members = {}
    for index, g in ipairs(honest) do
      local key = key_fn(g)
      if committed[key] ~= nil then
        members[key] = members[key] or {}
        table.insert(members[key], index)
      end
    end
    for key, member_indices in pairs(members) do
      local current = 0
      for _, index in ipairs(member_indices) do
        current = current + honest[index].duration
      end
      if committed[key] > current then
        commitments[#commitments + 1] = { members = member_indices, target = committed[key] }
        for _, index in ipairs(member_indices) do
          overcommitted[index] = true
        end
      end
    end
  end

  if #commitments == 0 then
    return honest, true
  end

  local result = quantize.constrained_quantize(granules, bucket_minutes, commitments)
  -- Feasibility guards the display's footing invariant. build_section_rows renders each committed cell
  -- as (logged = committed) + (remainder = cell_total - committed, dropped when <= 0), so a section
  -- foots iff every committed cell's final total is >= its committed value. The shift only inflates
  -- OVER-committed cells, but processing commitments in sequence can pull an exactly-met or
  -- under-committed cell -- whose own commitment was never collected -- BELOW its committed value; when
  -- any committed cell ends short, fall back to honest quantization (which foots) and signal it (false).
  -- Tag/location/workday are checked at the section scope build_section_rows displays. Level s, though,
  -- is enforced (and read back by fine_grained_quantized) per (text, tag, location) while the display
  -- aggregates locations; check it at that finer scope too, so one location's !S pulled below its
  -- committed value -- masked at the aggregate by another location's surplus -- still forces the honest
  -- fallback (and its contradiction warning) rather than silently drifting fine_grained's per-slice value.
  for _, level in ipairs({ "s", "t", "l", "w" }) do
    local key_fn = level == "s"
        and function(row)
          return M.activity_identity_key(row) .. "\0" .. (row.s_names_key or "")
        end
      or function(row)
        return cell_key(row, level)
      end
    local committed = committed_by_cell(intervals, level, key_fn)
    local totals = {}
    for _, g in ipairs(result) do
      local key = key_fn(g)
      totals[key] = (totals[key] or 0) + g.duration
    end
    for key, target in pairs(committed) do
      if (totals[key] or 0) < target then
        return honest, false
      end
    end
  end
  -- The inflation held (no fallback): a nudge on an over-committed granule is inert (the commitment
  -- dictates the value), so drop the nudge and its below-zero flag -- the marker must render nowhere and
  -- the "rounds below zero" warning is likewise moot. Durations are already set; only the display reads
  -- these fields.
  for index in pairs(overcommitted) do
    result[index].nudge = nil
    result[index].nudge_below_zero = nil
  end
  return result, true
end

local function key_of(row, key_fields)
  local parts = {}
  for _, field in ipairs(key_fields) do
    parts[#parts + 1] = tostring(row[field])
  end
  return table.concat(parts, "\0")
end

-- Build one report section (activities / tags / locations) from the shared quantized granules. The cell
-- TOTAL and nudge come from the granules (so every section re-sums the one quantization and foots),
-- while the logged/unlogged SPLIT comes from the intervals:
--   * a committed cell renders a logged row at `V` plus an unlogged row at `total - V`, the latter
--     omitted when 0 (an over-commitment already inflated the cell, so `total == V`);
--   * a cell with only bare markers, or none, renders one honest row.
-- The nudge marker rides the unlogged/plain (live) row; a frozen logged slice never carries one.
local function build_section_rows(quantized, intervals, key_fields, level, feasible)
  local total, nudge = {}, {}
  for _, g in ipairs(quantized) do
    local key = key_of(g, key_fields)
    total[key] = (total[key] or 0) + g.duration
    if g.nudge and g.nudge ~= 0 then
      nudge[key] = (nudge[key] or 0) + g.nudge
    end
  end

  -- Committed value per cell; when infeasible, every cell renders honestly (no split) so it still foots.
  local committed = feasible
      and committed_by_cell(intervals, level, function(interval)
        return key_of(interval, key_fields)
      end)
    or {}

  local cells, order = {}, {}
  for _, interval in ipairs(intervals) do
    local key = key_of(interval, key_fields)
    local cell = cells[key]
    if not cell then
      cell = {
        key = key,
        fields = {},
        logged_real = 0,
        unlogged_real = 0,
        logged_rows = {},
        unlogged_rows = {},
      }
      for _, field in ipairs(key_fields) do
        cell.fields[field] = interval[field]
      end
      -- The level's display name list (nil when unnamed) rides on every emitted row; the flat combine
      -- key is carried only for a named cell, so an unnamed row stays byte-identical to today.
      local names = interval[level .. "_names"]
      cell.fields.names = names
      cell.fields[level .. "_names_key"] = names and interval[level .. "_names_key"] or nil
      cells[key] = cell
      order[#order + 1] = cell
    end
    local marker = interval.logged_by_level and interval.logged_by_level[level]
    if marker ~= nil then
      cell.logged_real = cell.logged_real + interval.duration
      cell.logged_rows[#cell.logged_rows + 1] = interval.source_entry_row
      -- Marks the cell logged even when it renders as one honest row (bare marker, or infeasible).
      cell.logged = true
    else
      cell.unlogged_real = cell.unlogged_real + interval.duration
      cell.unlogged_rows[#cell.unlogged_rows + 1] = interval.source_entry_row
    end
  end

  local function with_fields(cell)
    local row = {}
    for field, value in pairs(cell.fields) do
      row[field] = value
    end
    return row
  end

  -- Only main summary rows carry source-entry provenance (:Daylog log / map / split / rename / balance
  -- read it); tag/location logging finds a cell's entries by its own field instead.
  local main = level == "s"

  local rows = {}
  for _, cell in ipairs(order) do
    local cell_total = total[cell.key] or 0
    local committed_value = committed[cell.key]
    if committed_value ~= nil then
      -- Backstop: never bill a logged row above the cell's real total. The feasibility guard already
      -- ensures committed_value <= cell_total; this keeps a section footing structurally regardless.
      committed_value = math.min(committed_value, cell_total)
      local remainder = cell_total - committed_value
      local logged = with_fields(cell)
      logged.logged = true
      -- The frozen commitment, so the fine-grained consumers (log/balance) can tell a committed slice
      -- (held at this value) from a bare `!S` marker (plain branch, no `logged_minutes`). Inert for the
      -- display, which reads only `duration`.
      logged.logged_minutes = committed_value
      logged.duration = committed_value
      -- Keep the section's rows a partition of the cell's real: the logged row absorbs the unmarked real
      -- only when the remainder row is dropped (remainder 0), so residuals match every other section.
      logged.unrounded_duration = cell.logged_real + (remainder > 0 and 0 or cell.unlogged_real)
      logged.source_entry_rows = main and cell.logged_rows or nil
      rows[#rows + 1] = logged

      if remainder > 0 then
        local unlogged = with_fields(cell)
        unlogged.duration = remainder
        unlogged.unrounded_duration = cell.unlogged_real
        unlogged.source_entry_rows = main and cell.unlogged_rows or nil
        unlogged.nudge = nudge[cell.key]
        rows[#rows + 1] = unlogged
      end
    else
      local row = with_fields(cell)
      row.logged = cell.logged or nil
      row.duration = cell_total
      row.unrounded_duration = cell.logged_real + cell.unlogged_real
      row.nudge = nudge[cell.key]
      if main then
        row.source_entry_rows = {}
        for _, source_row in ipairs(cell.logged_rows) do
          row.source_entry_rows[#row.source_entry_rows + 1] = source_row
        end
        for _, source_row in ipairs(cell.unlogged_rows) do
          row.source_entry_rows[#row.source_entry_rows + 1] = source_row
        end
      end
      rows[#rows + 1] = row
    end
  end

  return quantize.apply_error_minutes(rows)
end

local function sort_by_duration(items)
  local indexed = {}

  for i, item in ipairs(items) do
    table.insert(indexed, {
      index = i,
      item = item,
    })
  end

  table.sort(indexed, function(a, b)
    if a.item.duration == b.item.duration then
      local a_unrounded = a.item.unrounded_duration or a.item.duration
      local b_unrounded = b.item.unrounded_duration or b.item.duration

      if a_unrounded ~= b_unrounded then
        return a_unrounded > b_unrounded
      end

      return a.index < b.index
    end

    return a.item.duration > b.item.duration
  end)

  for i, indexed_item in ipairs(indexed) do
    items[i] = indexed_item.item
  end

  return items
end

-- Group `items` by `key_fn`, order each group's rows then the groups by displayed duration, and
-- flatten back in place -- so a cell's rows (a committed logged slice and its remainder) stay adjacent
-- instead of being split by an unrelated row of intermediate duration. nil keys share one group.
local function sort_grouped(items, key_fn)
  local groups_by_key = {}
  local groups = {}
  local ordered = {}

  for _, item in ipairs(items) do
    local key = key_fn(item)
    if key == nil then
      key = "\0"
    end

    local group = groups_by_key[key]
    if not group then
      group = { items = {}, duration = 0, unrounded_duration = 0 }
      groups_by_key[key] = group
      table.insert(groups, group)
    end

    table.insert(group.items, item)
    group.duration = group.duration + item.duration
    group.unrounded_duration = group.unrounded_duration + (item.unrounded_duration or item.duration)
  end

  for _, group in ipairs(groups) do
    sort_by_duration(group.items)
  end

  sort_by_duration(groups)

  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do
      table.insert(ordered, item)
    end
  end

  for i, item in ipairs(ordered) do
    items[i] = item
  end

  return items
end

-- Main rows group by activity text; tag/location totals group by their own cell so a committed cell's
-- logged + remainder slices render adjacently (footing is unaffected -- grouping only reorders rows).
local function finalize_summary_order(summary)
  sort_grouped(summary.summary_items, function(item)
    return item.text
  end)
  sort_grouped(summary.tag_totals, function(item)
    return item.tag
  end)
  sort_grouped(summary.location_totals, function(item)
    return item.location
  end)
  return summary
end

-- Build the full quantized summary from one shared quantization: every section re-sums the same
-- granules, so all foot to the one activity total.
function M.summarize_entries(entries, quantize_minutes)
  local bucket_minutes = bucket_of(quantize_minutes)
  local intervals = build_intervals(entries)
  local quantized, feasible =
    quantize_granules(build_granules(intervals), intervals, bucket_minutes)

  local activity_total, activity_real = 0, 0
  for _, g in ipairs(quantized) do
    activity_total = activity_total + g.duration
    activity_real = activity_real + (g.unrounded_duration or g.duration)
  end

  return finalize_summary_order({
    summary_items = build_section_rows(
      quantized,
      intervals,
      { "text", "tag", "s_names_key" },
      "s",
      feasible
    ),
    tag_totals = build_section_rows(quantized, intervals, { "tag", "t_names_key" }, "t", feasible),
    location_totals = build_section_rows(
      quantized,
      intervals,
      { "location", "l_names_key" },
      "l",
      feasible
    ),
    -- Blank entries never reach a granule, so the totals are one `workday` cell per name-set (!W).
    total_rows = build_section_rows(quantized, intervals, { "w_names_key" }, "w", feasible),
    activity_total = activity_total,
    activity_error_minutes = activity_real - activity_total,
  })
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries, block.quantize_minutes)
end

-- The activity rows the logging and balance use cases reason over, split per
-- (text, tag, location, s_names_key) with `source_entry_rows`, `nudge`, `unrounded_duration`, quantized
-- `duration`, and `logged_minutes` on a committed slice. Built from the SAME granule quantization the
-- display renders (location kept in the key so an `!S` value is committed per activity+location), so the
-- value logging freezes always equals the value the summary shows -- they cannot drift apart.
function M.fine_grained_quantized(entries, quantize_minutes)
  local bucket_minutes = bucket_of(quantize_minutes)
  local intervals = build_intervals(entries)
  local quantized, feasible =
    quantize_granules(build_granules(intervals), intervals, bucket_minutes)
  return build_section_rows(
    quantized,
    intervals,
    { "text", "tag", "location", "s_names_key" },
    "s",
    feasible
  ),
    bucket_minutes
end

-- The quantized granules exactly as the displayed summary re-sums them, for callers judging
-- display-level facts (an out-of-range nudge) on the same base the render shows. PURE.
function M.quantized_granules(entries, quantize_minutes)
  local bucket_minutes = bucket_of(quantize_minutes)
  local intervals = build_intervals(entries)
  return (quantize_granules(build_granules(intervals), intervals, bucket_minutes))
end

-- The activity-identity key (resolved text, tag, location) EXCLUDING logged state, so an about-to-be-
-- logged row finds the already-logged row it merges with and conflict scans group across the divide.
-- One definition keeps merge key and conflict key from drifting. PURE.
function M.activity_identity_key(row)
  return table.concat({
    row.text or "",
    row.tag or "",
    row.location or "",
  }, "\0")
end

-- The grouping an interval's committed value must agree within, per level: activity (s), tag, location,
-- or the whole workday (w).
local function level_group_key(row, level)
  if level == "t" then
    return (row.tag or "") .. "\0" .. (row.t_names_key or "")
  elseif level == "l" then
    return (row.location or "") .. "\0" .. (row.l_names_key or "")
  elseif level == "w" then
    return "\0" .. (row.w_names_key or "")
  end
  return M.activity_identity_key(row) .. "\0" .. (row.s_names_key or "")
end

-- Same-level intervals whose committed values disagree, each { row } at the earliest entry: the fold
-- would silently collapse them to one, so catch it first. A bare marker is its own value (`!T` vs `!T60`
-- conflicts).
local function conflicts_at_level(intervals, level)
  local groups, order = {}, {}

  for _, interval in ipairs(intervals) do
    local committed = interval.logged_by_level and interval.logged_by_level[level]
    if committed ~= nil then
      local key = level_group_key(interval, level)
      local group = groups[key]
      if not group then
        group = { row = interval.source_entry_row, values = {}, distinct = 0 }
        groups[key] = group
        order[#order + 1] = group
      end

      local minutes = syntax.committed_minutes(committed)
      local token = minutes ~= nil and tostring(minutes) or "nil"
      if not group.values[token] then
        group.values[token] = true
        group.distinct = group.distinct + 1
      end
      if interval.source_entry_row < group.row then
        group.row = interval.source_entry_row
      end
    end
  end

  local conflicts = {}
  for _, group in ipairs(order) do
    if group.distinct > 1 then
      conflicts[#conflicts + 1] = { row = group.row }
    end
  end
  return conflicts
end

-- Public summary-level conflicts (the main rows :Daylog map / rename reason over). PURE.
function M.logged_value_conflicts(entries)
  return conflicts_at_level(build_intervals(entries), "s")
end

-- The noun each level's committed value belongs to, for diagnostic wording.
local LEVEL_NOUN = { s = "activity", t = "tag", l = "location", w = "workday" }

-- Semantic logging problems that make a block's summary untrustworthy, each { row, message }: a frozen
-- `!X<n>` off the bucket grid, or a level-group disagreeing on its committed value. Shared by refresh
-- (diagnostics) and the highlighter (reddening) so the two can never drift apart. PURE.
function M.logging_diagnostics(block)
  local out = {}
  local bucket = bucket_of(block.quantize_minutes)
  local intervals = build_intervals(block.entries)

  -- A frozen value off the bucket grid, reported once per level-group (anchored at its first entry).
  local seen_off_grid = {}
  for _, item in ipairs(block.entry_items) do
    for _, level in ipairs(syntax.LOGGED_LEVELS) do
      local committed = syntax.committed_minutes(item.logged and item.logged[level])
      if committed ~= nil and (committed < 0 or committed % bucket ~= 0) then
        local key = level .. "\0" .. level_group_key(item, level)
        if not seen_off_grid[key] then
          seen_off_grid[key] = true
          out[#out + 1] = {
            row = item.start_row,
            message = string.format(
              "daylog: a frozen !%s value no longer fits q=%d; re-run :Daylog log to recommit",
              level:upper(),
              bucket
            ),
          }
        end
      end
    end
  end

  -- Same-group entries disagreeing on a committed value.
  for _, level in ipairs(syntax.LOGGED_LEVELS) do
    for _, conflict in ipairs(conflicts_at_level(intervals, level)) do
      out[#out + 1] = {
        row = conflict.row,
        message = string.format(
          "daylog: logged entries for this %s disagree on their !%s value; "
            .. "re-run :Daylog log to recommit",
          LEVEL_NOUN[level],
          level:upper()
        ),
      }
    end
  end

  -- Cross-cutting commitments that cannot be jointly satisfied: quantize_granules fell back to honest
  -- quantization, so surface it rather than hide a committed value not being honored.
  local _, feasible = quantize_granules(build_granules(intervals), intervals, bucket)
  if not feasible then
    local anchor
    for _, item in ipairs(block.entry_items) do
      for _, level in ipairs(syntax.LOGGED_LEVELS) do
        if item.logged and syntax.committed_minutes(item.logged[level]) ~= nil then
          anchor = anchor or item.start_row
        end
      end
    end
    out[#out + 1] = {
      row = anchor or (block.entry_items[1] and block.entry_items[1].start_row) or 0,
      message = "daylog: these logged commitments contradict each other and can't all be honored; adjust one",
    }
  end

  return out
end

function M.combine_summaries(summaries)
  local summary_items = {}
  local tag_totals = {}
  local location_totals = {}
  local total_rows = {}
  local activity_total = 0
  local activity_error_minutes = 0

  for _, item in ipairs(summaries or {}) do
    activity_total = activity_total + item.activity_total
    activity_error_minutes = activity_error_minutes + (item.activity_error_minutes or 0)

    for _, row in ipairs(item.summary_items or {}) do
      table.insert(summary_items, row)
    end

    for _, row in ipairs(item.tag_totals or {}) do
      table.insert(tag_totals, row)
    end

    for _, row in ipairs(item.location_totals or {}) do
      table.insert(location_totals, row)
    end

    for _, row in ipairs(item.total_rows or {}) do
      table.insert(total_rows, row)
    end
  end

  local summary = {
    summary_items = quantize.apply_error_minutes(
      projection.project_rows(
        summary_items,
        { "text", "tag", "logged", "s_names_key" },
        { "text", "tag", "logged", "s_names_key", "names" }
      )
    ),
    -- `logged` and the level's name-set key are in the key so a section's logged/unlogged and
    -- differently-named rows stay separate across days (same-name rows merge).
    tag_totals = quantize.apply_error_minutes(
      projection.project_rows(
        tag_totals,
        { "tag", "logged", "t_names_key" },
        { "tag", "logged", "t_names_key", "names" }
      )
    ),
    location_totals = quantize.apply_error_minutes(
      projection.project_rows(
        location_totals,
        { "location", "logged", "l_names_key" },
        { "location", "logged", "l_names_key", "names" }
      )
    ),
    total_rows = quantize.apply_error_minutes(
      projection.project_rows(
        total_rows,
        { "logged", "w_names_key" },
        { "logged", "w_names_key", "names" }
      )
    ),
    activity_total = activity_total,
    activity_error_minutes = activity_error_minutes,
  }

  return finalize_summary_order(summary)
end

return M
