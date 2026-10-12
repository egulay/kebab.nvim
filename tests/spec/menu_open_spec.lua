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

local MENUS = { "kebab.menus.editor", "kebab.menus.tree", "kebab.menus.sql", "kebab.menus.dbtree" }

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

-- A menu that was clicked has to go away, including when its buffer is gone.
--
-- What happens in a real terminal: nvzone's click handler closes the clicked
-- menu with `volt.close(buf)`, which feeds `q` to a buffer-local mapping
-- through nvim_feedkeys. Called from inside a mouse-click handler that is
-- itself a feedkeys execution, the nested call does not run the mapping -- but
-- the buffer does get wiped, and Neovim leaves the float open showing an empty
-- one. The result is an empty bordered box over the screen that also holds the
-- focus, so a picker opened from a submenu came up unfocused in normal mode
-- and typing to filter did nothing.
--
-- Simulated here rather than clicked: a float carrying nvzone's own filetype,
-- then the same float with its buffer wiped, which is the case that cannot be
-- recognised by filetype and is why kebab.menus.action tracks the window.
H.describe("closing a menu that was clicked", function()
  local A = require("kebab.menus.action")

  local function float(ft)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 1, col = 1, width = 20, height = 3, style = "minimal",
    })
    if ft then
      vim.bo[buf].filetype = ft
    end
    return win, buf
  end

  H.it("closes a menu window still showing its own buffer", function()
    local win = float("NvMenu")
    local closed = A.close_menus()
    H.ok(closed >= 1, "it should have closed something")
    H.eq(false, vim.api.nvim_win_is_valid(win), "the menu float should be gone")
  end)

  H.it("closes a menu window whose buffer was already wiped", function()
    local win, buf = float("NvMenu")
    A.watch("kebab.menus.editor")
    vim.wait(200, function() return false end) -- let the scheduled scan run
    -- what the plugin does: wipe the buffer and leave the window behind
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if not vim.api.nvim_win_is_valid(win) then
      return H.ok(true, "this Neovim closed the float with its buffer")
    end
    A.close_menus()
    H.eq(false, vim.api.nvim_win_is_valid(win), "the leftover float should be closed")
  end)

  H.it("leaves another plugin's float alone", function()
    local win = float("snacks_picker_input")
    A.close_menus()
    local alive = vim.api.nvim_win_is_valid(win)
    pcall(vim.api.nvim_win_close, win, true)
    H.ok(alive, "only menu windows may be closed")
  end)

  H.it("runs the action anyway when there is no menu open", function()
    -- The deferral only applies when a menu was closed: a keymap or a test
    -- calls these directly and must still see the effect immediately.
    local hit = false
    local fn = A.custom("a test action", function() hit = true end, function() return true end)
    fn()
    H.ok(hit, "an action invoked with no menu open should run synchronously")
  end)
end)
