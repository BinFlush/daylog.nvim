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
      logged = current.logged and true or nil,
      -- The rounding nudge belongs to the entry that starts the interval; it sums
      -- up the fine-grained quantization row this interval folds into.
      nudge = current.nudge,
      -- A frozen committed value (minutes) rides on the entry that starts the
      -- interval. Every interval of one fine-grained row carries the same value (the
      -- row's committed duration), so the fold copies it through, never sums it. Gated
      -- on `logged` so a value left behind by an in-memory unmark can never freeze a
      -- now-unlogged row: a frozen value exists only alongside an active !L.
      logged_minutes = current.logged and current.logged_minutes or nil,
      source_entry_row = current.row,
    })
  end

  return intervals
end

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
    and (last.logged and true or nil) == item.logged
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

-- Emit logged totals in fixed semantic order: logged always before unlogged.
-- `by_logged` is keyed by the boolean logged state.
local function ordered_logged_totals(by_logged)
  local totals = {}

  if by_logged[true] then
    table.insert(totals, by_logged[true])
  end
  if by_logged[false] then
    table.insert(totals, by_logged[false])
  end

  return totals
end

-- Derive logged totals by projecting workday-eligible summary items by logged state.
-- Items must already carry quantized durations and error_minutes (i.e. they come from
-- quantize.project_quantized_items or an apply_error_minutes pass).  Duration,
-- unrounded_duration, and error_minutes are summed directly so the result equals the sum of
-- the visible quantized main summary rows by logged state, preserving the remainder
-- distribution from the shared quantization pass.
local function logged_totals_from_quantized_items(items)
  local buckets = {}
  local has_logged = false

  for _, item in ipairs(items or {}) do
    if not item.workday_excluded then
      local logged = item.logged == true
      has_logged = has_logged or logged

      local bucket = buckets[logged]
      if not bucket then
        bucket = {
          logged = logged,
          duration = 0,
          unrounded_duration = 0,
          error_minutes = 0,
        }
        buckets[logged] = bucket
      end

      bucket.duration = bucket.duration + item.duration
      bucket.unrounded_duration = bucket.unrounded_duration + (item.unrounded_duration or 0)
      bucket.error_minutes = bucket.error_minutes + (item.error_minutes or 0)
      if item.nudge and item.nudge ~= 0 then
        bucket.nudge = (bucket.nudge or 0) + item.nudge
      end
    end
  end

  if not has_logged then
    return nil
  end

  return ordered_logged_totals(buckets)
end

-- Apply the shared summary tail: attach the manual-nudge totals sparsely (only when
-- nonzero, so a log with no manual balancing produces the identical structure),
-- derive and attach the logged totals from the main rows, and order every section.
-- Both summarize_entries and combine_summaries finish through this so the
-- sparse-nudge and logged-totals invariants are defined once.
local function finalize_summary(summary, activity_nudge, workday_nudge)
  if activity_nudge ~= 0 then
    summary.activity_nudge = activity_nudge
  end
  if workday_nudge ~= 0 then
    summary.workday_nudge = workday_nudge
  end

  local logged_totals = logged_totals_from_quantized_items(summary.summary_items)
  if logged_totals then
    summary.logged_totals = logged_totals
  end

  return finalize_summary_order(summary)
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest configured bucket, each
-- fine-grained row is rounded down to that bucket, and the remaining
-- bucket-sized blocks are assigned to the largest remainders. Every displayed
-- quantized section is then projected from that one quantized fine-grained
-- base. `#ooo` rows participate in the same pass, but are excluded from the
-- final workday total.
function M.summarize_entries(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES
  local unrounded_rows = build_fine_grained_rows(build_intervals(entries))
  local unrounded_summary = build_summary_from_rows(unrounded_rows)
  local target_total =
    quantize.round_to_nearest_bucket(unrounded_summary.activity_total, bucket_minutes)
  local quantized_rows = quantize.quantize_rows(unrounded_rows, bucket_minutes, target_total)
  local quantized_summary = build_summary_from_rows(quantized_rows)

  local summary = {
    summary_items = quantize.project_quantized_items(
      unrounded_summary.summary_items,
      quantized_summary.summary_items,
      { "text", "tag", "workday_excluded", "logged" },
      { "text", "tag", "workday_excluded", "logged" }
    ),
    tag_totals = quantize.project_quantized_items(
      unrounded_summary.tag_totals,
      quantized_summary.tag_totals,
      { "tag" },
      { "tag" }
    ),
    location_totals = quantize.project_quantized_items(
      unrounded_summary.location_totals,
      quantized_summary.location_totals,
      { "location" },
      { "location" }
    ),
    activity_total = quantized_summary.activity_total,
    workday_total = quantized_summary.workday_total,
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

  local activity_total = 0
  for _, row in ipairs(unrounded_rows) do
    activity_total = activity_total + row.duration
  end

  local target_total = quantize.round_to_nearest_bucket(activity_total, bucket_minutes)
  return quantize.quantize_rows(unrounded_rows, bucket_minutes, target_total), bucket_minutes
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

-- Every logged interval that folds into one fine-grained row must carry the same
-- frozen value: :Daylog log writes the row's committed total onto each contributing
-- entry. The fold (build_fine_grained_rows) keeps logged_minutes as a first-seen
-- field, so disagreeing values -- from a hand edit or a partial operation -- would be
-- silently collapsed to one. This finds every such row instead, keyed by
-- activity_identity_key within the logged set, so it matches where the values actually
-- collapse. Returns a list of { row } anchored at the earliest conflicting entry; the
-- shell turns each into a diagnostic. A bare `!L` (unfrozen, no value) counts as its own
-- value, so mixing `!L` and `!L60` also conflicts.
function M.logged_value_conflicts(entries)
  local groups = {}
  local order = {}

  for _, interval in ipairs(build_intervals(entries)) do
    if interval.logged then
      local key = M.activity_identity_key(interval)

      local group = groups[key]
      if not group then
        group = { row = interval.source_entry_row, values = {}, distinct = 0 }
        groups[key] = group
        order[#order + 1] = group
      end

      local token = interval.logged_minutes == nil and "nil" or tostring(interval.logged_minutes)
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

function M.combine_summaries(summaries)
  local summary_items = {}
  local tag_totals = {}
  local location_totals = {}
  local activity_total = 0
  local workday_total = 0
  local activity_error_minutes = 0
  local workday_error_minutes = 0
  local activity_nudge = 0
  local workday_nudge = 0

  for _, item in ipairs(summaries or {}) do
    activity_total = activity_total + item.activity_total
    workday_total = workday_total + item.workday_total
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
    tag_totals = quantize.apply_error_minutes(
      projection.project_rows(tag_totals, { "tag" }, { "tag" })
    ),
    location_totals = quantize.apply_error_minutes(
      projection.project_rows(location_totals, { "location" }, { "location" })
    ),
    activity_total = activity_total,
    workday_total = workday_total,
    activity_error_minutes = activity_error_minutes,
    workday_error_minutes = workday_error_minutes,
  }

  return finalize_summary(summary, activity_nudge, workday_nudge)
end

return M
