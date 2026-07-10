-- Minimal init for the Telescope integration suite (`just test-telescope`). Adds the repo plus a
-- discovered telescope.nvim / plenary.nvim to the runtimepath so real Telescope runs headlessly, the
-- way Telescope's own scripts/minimal_init.vim does. Not used by the always-on suite.

vim.opt.runtimepath:append(".")

local data = vim.fn.stdpath("data")

-- Locate an installed plugin dir: lazy.nvim first, then a site/pack glob (start + opt).
local function find_plugin(name)
  local candidates = { data .. "/lazy/" .. name }
  for _, sub in ipairs({ "/site/pack/*/start/", "/site/pack/*/opt/" }) do
    for _, p in ipairs(vim.fn.glob(data .. sub .. name, true, true)) do
      candidates[#candidates + 1] = p
    end
  end
  for _, p in ipairs(candidates) do
    if vim.fn.isdirectory(p) == 1 then
      return p
    end
  end
  return nil
end

for _, name in ipairs({ "plenary.nvim", "telescope.nvim" }) do
  local path = find_plugin(name)
  if not path then
    io.stderr:write(
      "daylog integration tests need "
        .. name
        .. " installed (lazy.nvim or site/pack); none found under "
        .. data
        .. "\n"
    )
    vim.cmd("cq")
  end
  vim.opt.runtimepath:append(path)
end

vim.cmd("runtime! plugin/plenary.vim")
vim.cmd("runtime! plugin/telescope.lua")
