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
-- exclusion, and logged state that `build_intervals`/`summarize_items` key on. Lets identity edits
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

-- Main summary items fold across locations, concatenating provenance from
-- every fine-grained row that shares the same (text, tag, workday_excluded,
-- logged) identity.
local function summarize_items(rows)
  return projection.project_rows(
    rows,
    { "text", "tag", "workday_excluded", "logged" },
    { "text", "tag", "workday_excluded", "logged" },
    true
  )
end

local function summarize_metadata(rows, field)
  return projection.project_rows(rows, { field }, { field })
end

-- Project one row set into every reporting section.
-- Main summary items fold location away, while tag and location totals keep
-- their own label fields and all totals are derived from the same source rows.
local function build_summary_from_rows(rows)
  local activity_total = 0
  local workday_total = 0
  local activity_nudge = 0
  local workday_nudge = 0

  for _, row in ipairs(rows) do
    activity_total = activity_total + row.duration
    activity_nudge = activity_nudge + (row.nudge or 0)

    if not row.workday_excluded then
      workday_total = workday_total + row.duration
      workday_nudge = workday_nudge + (row.nudge or 0)
    end
  end

  return {
    summary_items = summarize_items(rows),
    tag_totals = summarize_metadata(rows, "tag"),
    location_totals = summarize_metadata(rows, "location"),
    activity_total = activity_total,
    workday_total = workday_total,
    activity_nudge = activity_nudge,
    workday_nudge = workday_nudge,
  }
end

-- Project the intervals into one report section (tags or locations), split by `level`'s logged flag
-- and quantized INDEPENDENTLY -- frozen-aware on that level's committed values. The section rounds its
-- own real totals, so it foots to its own returned total, which can differ from the main activity
-- total by a bucket once per-level commitments diverge (the intended multi-level behavior). `key_fields`
-- are the section's grouping fields ({ "tag" } / { "location" }). Because the fold is exactly the
-- grouping (no location to collapse, unlike main), the quantized rows are the display items directly.
--
-- #ooo time can never be logged, so a workday-excluded interval always lands in the section's UNLOGGED
-- slice regardless of any contradictory marker it carries -- logging_diagnostics surfaces the mistake.
local function append_field(list, field)
  local out = {}
  for i, value in ipairs(list) do
    out[i] = value
  end
  out[#out + 1] = field
  return out
end

local function project_section(intervals, key_fields, level, bucket_minutes)
  local group_fields = append_field(key_fields, "logged")
  local carry_fields = append_field(group_fields, "logged_minutes")

  local adapted = {}
  for _, interval in ipairs(intervals) do
    local committed = interval.logged_by_level and interval.logged_by_level[level]
    local logged = committed ~= nil and not interval.workday_excluded

    local row = { duration = interval.duration }
    for _, field in ipairs(key_fields) do
      row[field] = interval[field]
    end
    row.logged = logged or nil
    row.logged_minutes = (logged and type(committed) == "number") and committed or nil
    adapted[#adapted + 1] = row
  end

  -- No source-row provenance on tag/location rows: nothing reads it (diagnostics anchor via the block's
  -- entry_items), and omitting it keeps these rows the shape the reports and combine already expect.
  local rows = projection.project_rows(adapted, group_fields, carry_fields, false)
  local items = quantize.quantize_fine_grained(rows, bucket_minutes)

  local total = 0
  for _, item in ipairs(items) do
    total = total + item.duration
  end

  return items, total
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

local function finalize_summary_order(summary)
  sort_summary_items(summary.summary_items)
  sort_by_duration(summary.tag_totals)
  sort_by_duration(summary.location_totals)
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

  local unrounded_rows = build_fine_grained_rows(intervals)
  local unrounded_summary = build_summary_from_rows(unrounded_rows)
  local quantized_rows = quantize.quantize_fine_grained(unrounded_rows, bucket_minutes)
  local quantized_summary = build_summary_from_rows(quantized_rows)

  local tag_totals, tag_total = project_section(intervals, { "tag" }, "t", bucket_minutes)
  local location_totals, location_total =
    project_section(intervals, { "location" }, "l", bucket_minutes)

  local summary = {
    summary_items = quantize.project_quantized_items(
      unrounded_summary.summary_items,
      quantized_summary.summary_items,
      { "text", "tag", "workday_excluded", "logged" },
      { "text", "tag", "workday_excluded", "logged" }
    ),
    tag_totals = tag_totals,
    location_totals = location_totals,
    activity_total = quantized_summary.activity_total,
    workday_total = quantized_summary.workday_total,
    tag_total = tag_total,
    location_total = location_total,
    activity_error_minutes = unrounded_summary.activity_total - quantized_summary.activity_total,
    workday_error_minutes = unrounded_summary.workday_total - quantized_summary.workday_total,
  }

  return finalize_summary(
    summary,
    quantized_summary.activity_nudge,
    quantized_summary.workday_nudge
  )
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

  return out
end

function M.combine_summaries(summaries)
  local summary_items = {}
  local tag_totals = {}
  local location_totals = {}
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
