-- Integration tests for lua/daylog/telescope.lua against REAL Telescope, run via `just test-telescope`
-- (plenary busted). Pickers are opened for real and driven by the real Telescope actions / prompt once
-- populated; we assert daylog's callbacks fire.

local telescope = require("daylog.telescope")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

-- Open a picker (find() defers, so the prompt buffer appears asynchronously); wait until a populated
-- TelescopePrompt buffer exists and return its bufnr.
local function open(fn)
  fn()
  local bufnr
  local ready = vim.wait(3000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "TelescopePrompt" then
        local ok, picker = pcall(action_state.get_current_picker, b)
        if
          ok
          and type(picker) == "table"
          and picker.manager
          and picker.manager:num_results() > 0
        then
          bufnr = b
          return true
        end
      end
    end
    return false
  end, 10)
  assert.is_true(ready, "picker populated with results")
  return bufnr
end

local function set_prompt(bufnr, text)
  action_state.get_current_picker(bufnr):set_prompt(text)
  vim.wait(150)
end

-- Capture vim.notify for the duration of `fn`, returning the collected messages.
local function with_notify(fn)
  local messages = {}
  local old = vim.notify
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn, messages)
  vim.notify = old
  if not ok then
    error(err, 0)
  end
end

describe("daylog.telescope choose", function()
  local function run(overrides)
    local r = {}
    local bufnr = open(function()
      telescope.choose(
        {
          { display = "alpha row", text = "alpha" },
          { display = "beta row", text = "beta" },
        },
        vim.tbl_extend("force", {
          on_choose = function(t)
            r.chosen = t
          end,
          on_create = function(t)
            r.created = t
          end,
          on_cancel = function()
            r.cancelled = true
          end,
        }, overrides or {})
      )
    end)
    return bufnr, r
  end

  it("picks the highlighted row", function()
    local bufnr, r = run()
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.equal("alpha", r.chosen)
    assert.is_nil(r.created)
  end)

  it("creates from the typed prompt when nothing matches", function()
    local bufnr, r = run()
    set_prompt(bufnr, "brand new item")
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.equal("brand new item", r.created)
    assert.is_nil(r.chosen)
  end)

  it("calls on_cancel when closed without a pick", function()
    local bufnr, r = run()
    actions.close(bufnr)
    vim.wait(200)
    assert.is_true(r.cancelled)
  end)
end)

describe("daylog.telescope multi_select", function()
  local rows = {
    { display = "(unnamed)", name = "" },
    { display = "jira", name = "jira" },
    { display = "boss", name = "boss" },
  }
  local function run()
    local r = {}
    local bufnr = open(function()
      telescope.multi_select(rows, {
        on_select = function(names)
          r.selected = names
        end,
        on_cancel = function()
          r.cancelled = true
        end,
      })
    end)
    return bufnr, r
  end

  it("selects the highlighted row's name when nothing is toggled", function()
    local bufnr, r = run()
    local name = action_state.get_selected_entry().value.name
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.same({ name }, r.selected)
  end)

  it("confirms the toggled rows' names, sorted", function()
    local bufnr, r = run()
    actions.toggle_selection(bufnr)
    actions.move_selection_next(bufnr)
    actions.toggle_selection(bufnr)
    local names = {}
    for _, e in ipairs(action_state.get_current_picker(bufnr):get_multi_selection()) do
      names[#names + 1] = e.value.name
    end
    table.sort(names)
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.same(names, r.selected)
  end)

  it("creates comma-separated names from a non-matching prompt", function()
    local bufnr, r = run()
    set_prompt(bufnr, "alpha,beta")
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.same({ "alpha", "beta" }, r.selected)
  end)

  it("warns and stays open on an invalid typed name", function()
    with_notify(function(messages)
      local bufnr, r = run()
      set_prompt(bufnr, "bad name!") -- illegal character
      actions.select_default(bufnr)
      vim.wait(200)
      assert.is_nil(r.selected)
      assert.is_true(#messages >= 1)
    end)
  end)
end)

describe("daylog.telescope live_pick", function()
  local function source(search_impl)
    return {
      format_item = function(item)
        return item.title
      end,
      to_entry_text = function(item)
        return item.title
      end,
      search = search_impl,
    }
  end

  it("picks the selected item", function()
    local picked
    local bufnr = open(function()
      telescope.live_pick(source(function() end), {
        initial_items = { { id = "1", title = "one" }, { id = "2", title = "two" } },
        on_pick = function(v)
          picked = v
        end,
      })
    end)
    local expected = action_state.get_selected_entry().value
    actions.select_default(bufnr)
    vim.wait(200)
    assert.are.equal(expected.title, picked.title)
  end)

  it("runs a debounced server search and refreshes the pool", function()
    local searched
    local bufnr = open(function()
      telescope.live_pick(
        source(function(query, cb)
          searched = query
          cb({ { id = "9", title = "server " .. query } }, nil, nil)
        end),
        {
          initial_items = { { id = "1", title = "one" } },
          on_pick = function() end,
          min_query = 1,
        }
      )
    end)
    set_prompt(bufnr, "abc")
    vim.wait(700) -- past DEBOUNCE_MS (250) + the scheduled refresh
    assert.are.equal("abc", searched)
    -- The refresh merged the server item into the live pool; it survives the "abc" filter.
    local picker = action_state.get_current_picker(bufnr)
    local has_server = false
    for i = 1, picker.manager:num_results() do
      if picker.manager:get_entry(i).value.title == "server abc" then
        has_server = true
      end
    end
    assert.is_true(has_server, "the pool was refreshed with the server result")
  end)
end)
