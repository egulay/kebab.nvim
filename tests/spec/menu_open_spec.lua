-- Every menu must actually open.
--
-- The hole this fills: the sweeps walk a menu's entries with ipairs and check
-- each target exists, and menu_behaviour_spec runs the entries. None of them
-- ever called `menu.open`, so the tree's right-click menu could be -- and was
-- -- completely unopenable while every entry in it checked out.
--
-- The cause was a table of *functions* parked on the same table the menu
-- plugin iterates (`menu.actions = {...}`), which made its mappings.lua index
-- a function: "attempt to index local 'v' (a function value)". Anything that
-- is not an entry now hangs off a metatable instead, so `pairs()` yields only
-- entries. This spec fails if that is undone, for any menu.
local H = ...

local MENUS = { "kebab.menus.editor", "kebab.menus.tree", "kebab.menus.sql" }

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      out[#out + 1] = w
    end
  end
  return out
end

local function close_menus()
  pcall(function()
    require("menu.utils").delete_old_menus()
  end)
  for _, w in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, w, true)
  end
end

H.describe("opening a menu", function()
  H.it("has the plugin that draws them", function()
    pcall(function()
      require("lazy").load({ plugins = { "menu", "volt" } })
    end)
    local ok = pcall(require, "menu")
    H.ok(ok, "nvzone/menu should be installed")
  end)

  for _, name in ipairs(MENUS) do
    H.it(name .. " opens, and draws its entries", function()
      pcall(function()
        require("lazy").load({ plugins = { "menu", "volt" } })
      end)
      close_menus()
      local items = require(name)
      local ok, err = pcall(function()
        require("menu").open(items)
      end)
      local shown = floats()
      local labels = {}
      if #shown > 0 then
        local buf = vim.api.nvim_win_get_buf(shown[1])
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
          local text = ""
          for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
            text = text .. chunk[1]
          end
          if vim.trim(text) ~= "" then
            labels[#labels + 1] = vim.trim(text)
          end
        end
      end
      close_menus()
      H.ok(ok, ("%s should open: %s"):format(name, tostring(err)))
      H.ok(#shown > 0, name .. " should put a window on screen")
      -- The labels are virtual text, so a window with blank lines is normal;
      -- what matters is that the entries were drawn into it.
      H.ok(#labels > 0, name .. " should draw its entries, got none")
    end)

    H.it(name .. " carries nothing but entries on its list", function()
      -- The actual trap: the menu plugin iterates the table it is given and
      -- indexes every value. A helper parked on it as a named key -- a table
      -- of actions, a function -- is indistinguishable from an entry until it
      -- is indexed, and then the menu does not open at all.
      local items = require(name)
      local stowaways = {}
      for key, value in pairs(items) do
        if type(key) ~= "number" then
          stowaways[#stowaways + 1] = ("%s (%s)"):format(tostring(key), type(value))
        elseif type(value) ~= "table" then
          stowaways[#stowaways + 1] = ("[%d] is a %s"):format(key, type(value))
        end
      end
      H.eq({}, stowaways, "put helpers behind a metatable, not on the list")
    end)
  end
end)
