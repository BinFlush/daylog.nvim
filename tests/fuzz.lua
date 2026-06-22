-- CLI footing-fuzz sweep, parameterized via environment (set by `just fuzz`):
--   DAYLOG_FUZZ_MODE    a synth mode name or "all"                 [all]
--   DAYLOG_FUZZ_ROUNDS  logs per mode                          [5000]
--   DAYLOG_FUZZ_SEED    master RNG seed, or "random" to roll one   [1234567]
--                        (the resolved seed is printed for replay)
--
-- Runs only the footing fuzz (not the rest of the suite) and exits non-zero if
-- any log fails to foot. Always terminates nvim itself, so the recipe needs
-- no trailing +qa.

local footing = dofile(vim.fn.getcwd() .. "/tests/footing_check.lua")
local Rng = footing.Rng
local synth = footing.synth

-- Resolve and validate the env knobs. Raises (caught below) on bad input.
local function resolve()
  local mode_arg = os.getenv("DAYLOG_FUZZ_MODE")
  if mode_arg == nil or mode_arg == "" then
    mode_arg = "all"
  end
  local modes
  if mode_arg == "all" then
    modes = synth.MODES
  else
    for _, m in ipairs(synth.MODES) do
      if m == mode_arg then
        modes = { mode_arg }
      end
    end
    if not modes then
      error(
        string.format(
          "unknown mode %q (choose: all, %s)",
          mode_arg,
          table.concat(synth.MODES, ", ")
        ),
        0
      )
    end
  end

  local rounds_env = os.getenv("DAYLOG_FUZZ_ROUNDS")
  if rounds_env == nil or rounds_env == "" then
    rounds_env = "5000"
  end
  local rounds = tonumber(rounds_env)
  if not rounds or rounds < 1 or rounds % 1 ~= 0 then
    error(string.format("rounds must be a positive integer (got %q)", rounds_env), 0)
  end

  local seed_env = os.getenv("DAYLOG_FUZZ_SEED")
  if seed_env == nil or seed_env == "" then
    seed_env = "1234567"
  end
  local seed
  if seed_env == "random" then
    seed = os.time()
  else
    seed = tonumber(seed_env)
    if not seed or seed < 1 or seed % 1 ~= 0 then
      error(string.format('seed must be a positive integer or "random" (got %q)', seed_env), 0)
    end
  end

  return mode_arg, modes, rounds, seed
end

local function run(mode_arg, modes, rounds, seed)
  print(string.format("just fuzz: modes=%s  rounds=%d/mode  seed=%d", mode_arg, rounds, seed))

  local master = Rng.new(seed)
  local total_fails, total_runs = 0, 0
  local t0 = os.clock()
  for _, mode in ipairs(modes) do
    local mode_fails = 0
    for _ = 1, rounds do
      total_runs = total_runs + 1
      local err = footing.check(master:int(1, 2147483646), mode)
      if err then
        total_fails = total_fails + 1
        mode_fails = mode_fails + 1
        if mode_fails <= 3 then
          print(string.format("\nFAIL [%s]\n%s\n", mode, err))
        end
      end
    end
    print(string.format("  %-8s %6d rounds  %d failures", mode, rounds, mode_fails))
  end
  print(
    string.format(
      "\n%s -- swept %d logs in %.2fs (%d failures)",
      total_fails == 0 and "PASS" or "FAIL",
      total_runs,
      os.clock() - t0,
      total_fails
    )
  )
  return total_fails
end

local ok, result = pcall(function()
  return run(resolve())
end)

if not ok then
  io.stderr:write("just fuzz: " .. tostring(result) .. "\n")
  vim.cmd("cquit 2")
elseif result > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quitall!")
end
