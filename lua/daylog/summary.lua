local projection = require("daylog.projection")
local quantize = require("daylog.quantize")
local syntax = require("daylog.syntax")

local M = {}

-- Semantic reporting for log blocks.
--
-- Summaries are built directly from semantic entries or log blocks. This
-- module owns the log domain of reporting: interval derivation, the report
-- sections, sorting, and logged totals. The generic grouping engine lives in
-- projection.lua and the rounding arithmetic in quantize.lua.

-- The text an entry contributes to the summary: its mapping alias when set, else its
-- description. The original text stays on the entry; every grouping/display keys on this,
-- and so does the frecency ranker (sources/rank), so a bare and a mapped entry that report
-- as the same label rank as one activity.
function M.entry_summary_text(e)
  return (e.alias ~= nil and e.alias ~= "") and e.alias or e.text
end

local function build_intervals(entries)
  local intervals = {}

  for i = 1, #entries - 1 do
    local current = entries[i]
    local next_entry = entries[i + 1]

    -- Durations are measured in effective UTC time (`local - offset`), so an
    -- interval that spans a clock move -- a timezone crossing or a DST flip -- is
    -- its true length rather than the apparent local delta. `start`/`stop` stay the
    -- raw local clock (display only). With no offsets in play this is exactly
    -- `next.minutes - current.minutes`, so a plain log is unchanged.
    local current_effective = current.minutes - (current.offset or 0)
    local next_effective = next_entry.minutes - (next_entry.offset or 0)

    -- The row's scalar logged state is the summary (`s`) level of the entry's logged table: present
    -- means logged, a number there is the frozen committed value, `true` is a bare (unfrozen) marker.
    local logged_s = current.logged and current.logged.s

    table.insert(intervals, {
      start = current.minutes,
      stop = next_entry.minutes,
      duration = next_effective - current_effective,
      -- A mapping alias resolves the grouping/display label: an aliased entry counts
      -- toward, and is shown as, its target. The original text stays on the entry; every
      -- downstream grouping keys on this resolved `text`.
      text = M.entry_summary_text(current),
      tag = current.tag,
      location = current.location,
      workday_excluded = current.workday_excluded,
      logged = logged_s ~= nil and true or nil,
      -- The rounding nudge belongs to the entry that starts the interval; it sums
      -- up the fine-grained quantization row this interval folds into.
      nudge = current.nudge,
      -- A frozen committed value (minutes) rides on the entry that starts the
      -- interval. Every interval of one fine-grained row carries the same value (the
      -- row's committed duration), so the fold copies it through, never sums it. A bare
      -- marker (`s == true`) freezes nothing, so the row's `logged_minutes` stays nil and
      -- it rounds live like any un-frozen row.
      logged_minutes = type(logged_s) == "number" and logged_s or nil,
      -- The whole per-level logged table ({ level -> committed | true }), carried so the tag and
      -- location sections can split themselves by their own level (project_section). The `logged` /
      -- `logged_minutes` above are the summary (`s`) slice the main section and balance still key on.
      logged_by_level = current.logged,
      source_entry_row = current.row,
    })
  end

  return intervals
end

-- Exported for the time bar, which lays out the raw (real-duration) intervals directly.
M.build_intervals = build_intervals

-- The block's closing entry (its final entry) starts no interval, so its row never lands in a
-- summary item's `source_entry_rows` -- yet it still carries an activity identity. Return its row
-- when it WOULD group into `item` were another entry to follow it: same resolved text, tag, #ooo
-- exclusion, and logged state that `build_intervals`/`build_granules` key on. Lets identity edits
-- (:Daylog map / :Daylog rename) reach a same-activity entry that currently happens to close the log.
-- Returns nil when there is no entry or it does not match. `entries` is the block's `entries` list
-- (its `.row` equals the entry item's `start_row`, the coordinate the target sets use).
function M.closing_entry_row_for(entries, item)
  local last = entries[#entries]
  if not last then
    return nil
  end

  if
    M.entry_summary_text(last) == item.text
    and last.tag == item.tag
    and (last.workday_excluded or false) == (item.workday_excluded or false)
    and (last.logged and last.logged.s ~= nil and true or nil) == item.logged
  then
    return last.row
  end

  return nil
end

-- Fine-grained rows are the quantization base.
-- They preserve location so tag/location totals can be projected from the
-- same quantized rows, even though main summary rows do not render location.
-- Provenance accumulates here so each fine-grained row carries the source
-- entry rows of every interval that fed into it.
local function build_fine_grained_rows(intervals)
  return projection.project_rows(
    intervals,
    { "text", "tag", "location", "workday_excluded", "logged" },
    { "text", "tag", "location", "workday_excluded", "logged", "logged_minutes" },
    true,
    -- All intervals of one fine-grained row carry that row's single nudge, so fold
    -- by value (max magnitude), not by sum: marking some or all of an activity's
    -- identically-keyed intervals yields the same row nudge, never a multiple.
    "max"
  )
end

-- The cell an interval/granule belongs to at each level: an activity for the summary level, a tag / a
-- location for those, and the work-class (workday vs non-work) for the totals level. #ooo time is the
-- non-work cell and can never be logged, so `w` only ever commits the workday cell.
local function cell_key(row, level)
  if level == "t" then
    return row.tag or "\0notag"
  elseif level == "l" then
    return row.location or "\0noloc"
  elseif level == "w" then
    return row.workday_excluded and "non-work" or "workday"
  end
  return table.concat({ row.text or "", row.tag or "", row.workday_excluded and "1" or "0" }, "\0")
end

-- Group intervals into granules -- the finest cell every partition coarsens: (text, tag, location,
-- workday_excluded). Each granule carries its real duration, its balance nudge (shared across its
-- entries, so folded by "max"), the per-level committed table (`logged_by_level`, identical within a
-- granule since a commitment is written on all a cell's entries), and source provenance.
local function build_granules(intervals)
  return projection.project_rows(
    intervals,
    { "text", "tag", "location", "workday_excluded" },
    { "text", "tag", "location", "workday_excluded", "logged_by_level" },
    true,
    "max"
  )
end

-- The committed value of each cell at `level`, summed across the cell's distinct commitment sub-scopes.
-- A summary-level (`!S`) commitment is frozen per (activity, location) slice (log_current.frozen_values
-- keys by activity_identity_key), so an activity spanning locations carries several `!S` values that
-- must be SUMMED, never last-wins; a tag/location/workday commitment is one value shared across the
-- whole cell, so it is counted once. `cell_key_fn(interval)` groups intervals into the cells the caller
-- wants -- the section cell for display, the per-granule/per-cell inflation scope for quantization.
-- Read from the intervals (robust to how granules fold). #ooo never commits.
local function committed_by_cell(intervals, level, cell_key_fn)
  local scopes = {}
  for _, interval in ipairs(intervals) do
    local value = interval.logged_by_level and interval.logged_by_level[level]
    if type(value) == "number" and not interval.workday_excluded then
      local cell = cell_key_fn(interval)
      local scope = level == "s" and M.activity_identity_key(interval) or cell
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

-- Honest largest-remainder quantization of the granules, then SURPLUS inflation: for each committed
-- cell whose commitment exceeds the cell's honest rounded total, raise the cell's granules to the
-- committed value (distributing the surplus to the largest remainders). A commitment at or below the
-- honest total does NOT move a granule -- its "reported vs remaining" split is a display concern
-- (build_section_rows), so the cell stays at its honest total and every partition still foots. The
-- inflation SCOPE differs by level: `!S` is per (activity, location) granule, so each granule carries
-- its own value; `!T`/`!L`/`!W` are one value over all a cell's granules. Returns the quantized granules
-- (with `duration`, `unrounded_duration`, `error_minutes`).
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

  -- Collect only the OVER-committed cells (committed value beyond the cell's honest total): their
  -- surplus must inflate the cell and propagate. A commitment at or below its honest total leaves the
  -- granules alone (split at display time). The inflation scope is per-granule for `!S`
  -- (activity_identity_key, incl. location) and per-cell for `!T`/`!L`/`!W`; committed_by_cell sums a
  -- location-spanning `!S` correctly rather than last-wins. Index order is preserved from `granules`, so
  -- member lists index straight into constrained_quantize's copy.
  local commitments = {}
  for _, level in ipairs({ "s", "t", "l", "w" }) do
    local key_fn = level == "s" and function(row)
      return M.activity_identity_key(row)
    end or function(row)
      return cell_key(row, level)
    end
    local committed = committed_by_cell(intervals, level, key_fn)

    local members = {}
    for index, g in ipairs(honest) do
      if not g.workday_excluded then
        local key = key_fn(g)
        if committed[key] ~= nil then
          members[key] = members[key] or {}
          table.insert(members[key], index)
        end
      end
    end
    for key, member_indices in pairs(members) do
      local current = 0
      for _, index in ipairs(member_indices) do
        current = current + honest[index].duration
      end
      if committed[key] > current then
        commitments[#commitments + 1] = { members = member_indices, target = committed[key] }
      end
    end
  end

  if #commitments == 0 then
    return honest, true
  end

  local result = quantize.constrained_quantize(granules, bucket_minutes, commitments)
  -- Feasibility. constrained_quantize applies commitments sequentially, so two over-committed cells at
  -- different levels sharing a granule with contradictory targets (cross-cutting / non-laminar) can
  -- leave a later commitment violating an earlier one. If any committed cell's members no longer sum to
  -- its target, the set is jointly infeasible: fall back to the honest quantization -- so every section
  -- still foots honestly instead of fabricating a value -- and signal it, so build_section_rows renders
  -- without the split and logging_diagnostics warns.
  for _, commitment in ipairs(commitments) do
    local sum = 0
    for _, index in ipairs(commitment.members) do
      sum = sum + result[index].duration
    end
    if sum ~= commitment.target then
      return honest, false
    end
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

-- Build one report section (activities / tags / locations) from the shared quantized granules, split by
-- `level`'s marker. The cell TOTAL and any balance nudge come from the granules -- so every section is a
-- re-sum of the one quantization and they all foot -- while the logged/unlogged SPLIT comes from the
-- intervals (the source of truth for which entries carry the marker and its committed value):
--   * a committed cell renders a logged row shown at `V` plus an unlogged row shown at `total - V` (the
--     honest remainder, which absorbs the commitment's over/under-shoot); the unlogged row is omitted
--     when 0 (an over-commitment already inflated the cell in quantize_granules, so `total == V`);
--   * a cell with only bare markers, or none, renders one honest row.
-- Row residuals come from each slice's real duration; provenance is the slice's source rows, so
-- :Daylog log / map / balance can recover the entries behind a rendered row. The nudge marker rides the
-- unlogged/plain row (the live part); a frozen logged slice never carries one.
local function build_section_rows(quantized, intervals, key_fields, level, feasible)
  local total, nudge = {}, {}
  for _, g in ipairs(quantized) do
    local key = key_of(g, key_fields)
    total[key] = (total[key] or 0) + g.duration
    if g.nudge and g.nudge ~= 0 then
      nudge[key] = (nudge[key] or 0) + g.nudge
    end
  end

  -- The committed value per cell, summed across sub-scopes so a location-spanning `!S` is not last-wins.
  -- When the commitment set is jointly infeasible (cross-cutting contradiction), `feasible` is false and
  -- every cell renders honestly (no split) so the section still foots -- the contradiction is surfaced
  -- separately by logging_diagnostics.
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
      cells[key] = cell
      order[#order + 1] = cell
    end
    local marker = interval.logged_by_level and interval.logged_by_level[level]
    if marker ~= nil and not interval.workday_excluded then
      cell.logged_real = cell.logged_real + interval.duration
      cell.logged_rows[#cell.logged_rows + 1] = interval.source_entry_row
      -- The committed VALUE comes from committed_by_cell; this flag marks the cell logged even when it
      -- renders as one honest row (a bare marker, or a commitment suppressed because infeasible).
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

  -- Only the main summary rows carry source-entry provenance: :Daylog log / map / split / rename /
  -- balance act on activity rows and read it. Tag/location logging finds a cell's entries by its own
  -- field (log_current.log_section_row), so those rows stay provenance-free, as they always have.
  local main = level == "s"

  local rows = {}
  for _, cell in ipairs(order) do
    local cell_total = total[cell.key] or 0
    local committed_value = committed[cell.key]
    if committed_value ~= nil then
      local remainder = cell_total - committed_value
      local logged = with_fields(cell)
      logged.logged = true
      logged.duration = committed_value
      -- The logged row carries the marked entries' real. When the remaining slice is shown as its own
      -- row it carries the unmarked real; when it is dropped -- an over-commitment inflated the cell so
      -- remainder is 0 -- no other row carries the unmarked real, so the logged row absorbs it. This
      -- keeps a section's rows a partition of the cell's real (their unrounded durations sum to it), so
      -- this row's residual matches every other section that shows the same inflated time.
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

local function sort_summary_items(items)
  local groups_by_text = {}
  local groups = {}
  local ordered = {}

  for _, item in ipairs(items) do
    local group = groups_by_text[item.text]

    if not group then
      group = {
        text = item.text,
        items = {},
        duration = 0,
        unrounded_duration = 0,
      }
      groups_by_text[item.text] = group
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

-- The totals partition renders workday-first (it is the primary total, shown alone when there is no
-- #ooo), then the non-work cell -- a fixed order rather than by-duration, so the non-work row appears
-- below the workday rows when #ooo time exists instead of reordering them.
local function order_total_rows(rows)
  local ordered = {}
  for _, row in ipairs(rows) do
    if not row.workday_excluded then
      ordered[#ordered + 1] = row
    end
  end
  for _, row in ipairs(rows) do
    if row.workday_excluded then
      ordered[#ordered + 1] = row
    end
  end
  return ordered
end

local function finalize_summary_order(summary)
  sort_summary_items(summary.summary_items)
  sort_by_duration(summary.tag_totals)
  sort_by_duration(summary.location_totals)
  if summary.total_rows then
    summary.total_rows = order_total_rows(summary.total_rows)
  end
  return summary
end

-- Apply the shared summary tail: attach the manual-nudge totals sparsely (only when nonzero, so a log
-- with no manual balancing produces the identical structure), then order every section. Both
-- summarize_entries and combine_summaries finish through this so the sparse-nudge invariant is defined
-- once. The per-level logged/unlogged split lives inside each section now, not in a separate section.
local function finalize_summary(summary, activity_nudge, workday_nudge)
  if activity_nudge ~= 0 then
    summary.activity_nudge = activity_nudge
  end
  if workday_nudge ~= 0 then
    summary.workday_nudge = workday_nudge
  end

  return finalize_summary_order(summary)
end

-- Build the full quantized summary for a set of entries.
-- The MAIN summary (and the activity/workday totals) is quantized on the one shared summary-level base:
-- the activity total rounds to the nearest bucket, each fine-grained row rounds down, and the remaining
-- bucket blocks go to the largest remainders. The main section already splits by the summary (`s`)
-- level, and the balance system reads this same base, so it is left verbatim.
-- The TAG and LOCATION sections quantize INDEPENDENTLY, each split by its own level (`t` / `l`) and
-- footing to its own total (project_section). `#ooo` rows participate everywhere but are excluded from
-- the workday total and can never be logged.
function M.summarize_entries(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES
  local intervals = build_intervals(entries)
  -- One shared quantization: granules (text, tag, location, work-class), rounded honestly + inflated
  -- only where a commitment over-shoots. Every partition is a re-sum of these same granules, so all
  -- foot to the same total and residual; commitments split a cell for DISPLAY (build_section_rows).
  local quantized, feasible =
    quantize_granules(build_granules(intervals), intervals, bucket_minutes)

  local activity_total, activity_real, activity_nudge = 0, 0, 0
  local workday_total, workday_real, workday_nudge = 0, 0, 0
  for _, g in ipairs(quantized) do
    activity_total = activity_total + g.duration
    activity_real = activity_real + (g.unrounded_duration or g.duration)
    activity_nudge = activity_nudge + (g.nudge or 0)
    if not g.workday_excluded then
      workday_total = workday_total + g.duration
      workday_real = workday_real + (g.unrounded_duration or g.duration)
      workday_nudge = workday_nudge + (g.nudge or 0)
    end
  end

  local summary = {
    summary_items = build_section_rows(
      quantized,
      intervals,
      { "text", "tag", "workday_excluded" },
      "s",
      feasible
    ),
    tag_totals = build_section_rows(quantized, intervals, { "tag" }, "t", feasible),
    location_totals = build_section_rows(quantized, intervals, { "location" }, "l", feasible),
    -- The totals are a fourth partition: the workday cell (non-#ooo, loggable via !W) and the non-work
    -- cell (#ooo, never logged), which foot to the activity total exactly like tags and locations.
    total_rows = build_section_rows(quantized, intervals, { "workday_excluded" }, "w", feasible),
    activity_total = activity_total,
    workday_total = workday_total,
    -- Every section is a re-sum of the same granules, so tag/location foot to the activity total.
    tag_total = activity_total,
    location_total = activity_total,
    activity_error_minutes = activity_real - activity_total,
    workday_error_minutes = workday_real - workday_total,
  }

  return finalize_summary(summary, activity_nudge, workday_nudge)
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries, block.quantize_minutes)
end

-- The quantized fine-grained rows for a set of entries: the rounding-balance
-- granule keyed by text+tag+location+workday_excluded+logged, each carrying its
-- unrounded_duration, its quantized `duration` (with any current `nudge` applied),
-- its current `nudge`, and `source_entry_rows` provenance. The balance calculator
-- reasons over these to pick which row to nudge and which source entry to mark.
function M.fine_grained_quantized(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES
  local unrounded_rows = build_fine_grained_rows(build_intervals(entries))
  return quantize.quantize_fine_grained(unrounded_rows, bucket_minutes), bucket_minutes
end

-- The activity-identity key of a fine-grained row or interval, EXCLUDING its logged state:
-- the resolved text, tag, location, and #ooo exclusion that decide which fine-grained row an
-- interval folds into. Logged is deliberately omitted, so an about-to-be-logged row finds the
-- already-logged row of the same activity it will merge with (:Daylog log), and a logged-value
-- conflict scan groups across the logged/unlogged divide. One definition keeps the merge key
-- and the conflict key from drifting. (Distinct from the summary-item key, which carries
-- logged but not location.) PURE.
function M.activity_identity_key(row)
  return table.concat({
    row.text or "",
    row.tag or "",
    row.location or "",
    row.workday_excluded and "1" or "0",
  }, "\0")
end

-- The grouping an interval's committed logged value must agree within, per level: an activity for the
-- summary level, a tag / a location for those, the whole workday for `w` (one group).
local function level_group_key(row, level)
  if level == "t" then
    return row.tag or ""
  elseif level == "l" then
    return row.location or ""
  elseif level == "w" then
    return ""
  end
  return M.activity_identity_key(row)
end

-- Same-<level> intervals whose committed logged values disagree, each { row } anchored at the earliest
-- entry. :Daylog log writes one committed total onto every entry of the level's group; a hand edit or a
-- partial operation can leave them disagreeing, which the fold would silently collapse to one -- this
-- catches it first. A bare marker counts as its own value, so mixing `!T` and `!T60` also conflicts.
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

      local token = type(committed) == "number" and tostring(committed) or "nil"
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

-- Semantic logging problems in a block that make its summary untrustworthy, each { row, message }, for
-- every level (`!S`/`!T`/`!L`/`!W`):
--   * a frozen `!X<n>` value that no longer fits the block's bucket (a hand-edit or a q change),
--   * out-of-office (`#ooo`) time marked logged at any level (:Daylog log refuses it; a hand-edit slips
--     it in),
--   * entries of one level-group disagreeing on their committed value.
-- One detector shared by refresh (which raises these as diagnostics) and the highlighter (which reddens
-- the summary while any are present), so the warning and the red flag can never drift apart. PURE.
function M.logging_diagnostics(block)
  local out = {}
  local bucket = block.quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES
  local intervals = build_intervals(block.entries)

  -- A frozen value off the bucket grid, reported once per level-group (anchored at its first entry).
  local seen_off_grid = {}
  for _, item in ipairs(block.entry_items) do
    for _, level in ipairs(syntax.LOGGED_LEVELS) do
      local committed = item.logged and item.logged[level]
      if type(committed) == "number" and (committed < 0 or committed % bucket ~= 0) then
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

  -- Out-of-office time can never be logged, at any level.
  for _, item in ipairs(block.entry_items) do
    if item.workday_excluded and item.logged then
      for _, level in ipairs(syntax.LOGGED_LEVELS) do
        if item.logged[level] then
          out[#out + 1] = {
            row = item.start_row,
            message = "daylog: out-of-office time cannot be logged; remove !"
              .. level:upper()
              .. " or #ooo",
          }
          break
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

  -- Cross-cutting commitments that cannot be jointly satisfied: two over-committed cells at different
  -- levels share a granule with contradictory targets. quantize_granules then falls back to the honest
  -- quantization (so every section still foots) and signals it here, so a committed value silently not
  -- being honored is surfaced rather than hidden. Anchored at the earliest committed entry.
  local _, feasible = quantize_granules(build_granules(intervals), intervals, bucket)
  if not feasible then
    local anchor
    for _, item in ipairs(block.entry_items) do
      for _, level in ipairs(syntax.LOGGED_LEVELS) do
        if item.logged and type(item.logged[level]) == "number" then
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
  local workday_total = 0
  local tag_total = 0
  local location_total = 0
  local activity_error_minutes = 0
  local workday_error_minutes = 0
  local activity_nudge = 0
  local workday_nudge = 0

  for _, item in ipairs(summaries or {}) do
    activity_total = activity_total + item.activity_total
    workday_total = workday_total + item.workday_total
    tag_total = tag_total + (item.tag_total or item.activity_total)
    location_total = location_total + (item.location_total or item.activity_total)
    activity_error_minutes = activity_error_minutes + (item.activity_error_minutes or 0)
    workday_error_minutes = workday_error_minutes + (item.workday_error_minutes or 0)
    activity_nudge = activity_nudge + (item.activity_nudge or 0)
    workday_nudge = workday_nudge + (item.workday_nudge or 0)

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
        { "text", "tag", "workday_excluded", "logged" },
        { "text", "tag", "workday_excluded", "logged" }
      )
    ),
    -- The `logged` field is part of the key so a tag's/location's logged and unlogged rows stay
    -- separate across days (each section already carries its own split).
    tag_totals = quantize.apply_error_minutes(
      projection.project_rows(tag_totals, { "tag", "logged" }, { "tag", "logged" })
    ),
    location_totals = quantize.apply_error_minutes(
      projection.project_rows(location_totals, { "location", "logged" }, { "location", "logged" })
    ),
    total_rows = quantize.apply_error_minutes(
      projection.project_rows(
        total_rows,
        { "workday_excluded", "logged" },
        { "workday_excluded", "logged" }
      )
    ),
    activity_total = activity_total,
    workday_total = workday_total,
    tag_total = tag_total,
    location_total = location_total,
    activity_error_minutes = activity_error_minutes,
    workday_error_minutes = workday_error_minutes,
  }

  return finalize_summary(summary, activity_nudge, workday_nudge)
end

return M
