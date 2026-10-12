-- The right-click menu in the data source tree.
--
-- The editor menu was being shown here, which offered nothing about the thing
-- under the pointer: right-clicking a table gave "Browse Tables..." and then
-- asked which table. The point of right-clicking a table is that you have
-- already said which.
--
-- Every entry acts on the node the cursor is on, resolved by
-- kebab.dbide.node_at_cursor -- the same function the double click uses, so
-- the two cannot disagree about what was clicked. An entry that needs a table
-- says so when there is none, rather than doing something else quietly.
local A = require("kebab.menus.action")
local editor = require("kebab.menus.editor")

---@return table|nil node, string|nil why
local function node()
  local found = require("kebab.dbide").node_at_cursor()
  if not found then
    return nil, "put the cursor on a connection or a table first"
  end
  return found, nil
end

---An action that needs a table under the cursor.
---@param label string
---@param fn fun(c: kebab.DbConnection, table_name: string)
---@param check fun(): boolean, string|nil
local function on_table(label, fn, check)
  return A.custom(label, function()
    local found, why = node()
    if not found then
      return vim.notify(why, vim.log.levels.WARN)
    end
    if not found.table then
      return vim.notify(
        ("%s needs a table; the cursor is on %s"):format(label, found.connection.name),
        vim.log.levels.WARN
      )
    end
    fn(found.connection, found.table)
  end, check)
end

---An action that only needs the connection the cursor is somewhere inside.
local function on_connection(label, fn, check)
  return A.custom(label, function()
    local found, why = node()
    if not found then
      return vim.notify(why, vim.log.levels.WARN)
    end
    fn(found.connection, found.table)
  end, check)
end

-- The checks are what the menu sweep runs: each has to prove its target is
-- reachable now, in a loaded editor, without clicking anything.
local function dbide_has(name)
  return function()
    local I = require("kebab.dbide")
    if type(I[name]) ~= "function" then
      return false, ("kebab.dbide." .. name .. " is missing")
    end
    return true
  end
end

local items = {
  {
    name = "Open the Rows",
    cmd = on_table("open the table's rows", function(c, table_name)
      require("kebab.dbide").open_table(c, table_name)
    end, dbide_has("open_table")),
  },
  {
    name = "Structure (columns, keys, indexes)",
    rtxt = ":IdeDbStructure",
    cmd = on_table("show the table's structure", function(c, table_name)
      require("kebab.dbide").show_structure(c, table_name)
    end, dbide_has("show_structure")),
  },
  {
    name = "Count the Rows",
    rtxt = ":IdeDbCount",
    cmd = on_table("count the table's rows", function(c, table_name)
      local I = require("kebab.dbide")
      I.layout(c)
      I.run(c, ("select count(*) as rows from %s"):format(table_name))
    end, dbide_has("run")),
  },
  {
    name = "Copy the Table's Name",
    cmd = on_table("copy the table's name", function(_, table_name)
      vim.fn.setreg('"', table_name)
      vim.fn.setreg("+", table_name)
      vim.notify("Copied: " .. table_name)
    end, function()
      -- the registers are the whole implementation, so prove they take a value
      local saved = vim.fn.getreg('"')
      vim.fn.setreg('"', "kebab-dbtree-check")
      local ok = vim.fn.getreg('"') == "kebab-dbtree-check"
      vim.fn.setreg('"', saved)
      if not ok then
        return false, "the unnamed register did not take the value"
      end
      return true
    end),
  },

  { name = "separator" },

  {
    name = "New Statement Here",
    rtxt = "<leader>Dq",
    cmd = on_connection("new statement on this connection", function(c)
      require("kebab.dbide").new_query(c)
    end, dbide_has("new_query")),
  },
  {
    name = "Test This Connection",
    rtxt = "<leader>Dp",
    cmd = on_connection("test this connection", function(c)
      local banner, err = require("kebab.db").ping(c)
      if not banner then
        return vim.notify(tostring(err), vim.log.levels.ERROR)
      end
      vim.notify(("%s: %s"):format(c.name, banner))
    end, function()
      if type(require("kebab.db").ping) ~= "function" then
        return false, "kebab.db.ping is missing"
      end
      return true
    end),
  },

  { name = "separator" },
}

-- ...then the dadbod-ui tree's own keys, which are what a keyboard user
-- already has here, and the rest of the editor menu so nothing is lost.
items[#items + 1] = {
  name = "Tree",
  items = {
    -- Not `:DBUIRedraw` (no such command) and not `:normal! R` (normal! is
    -- precisely the form that ignores the mapping it was supposed to trigger).
    -- dadbod-ui exposes the action as a <Plug> mapping, so that is what is fed.
    {
      name = "Redraw the Tree",
      rtxt = "R",
      cmd = A.custom("redraw the data source tree", function()
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>(DBUI_Redraw)", true, false, true), "mx", false)
      end, function()
        -- dadbod-ui is a lazy spec, so its autoload directory is not on the
        -- runtimepath until it is loaded -- the same reason A.ex takes a
        -- `plugin` option for commands.
        pcall(function()
          require("lazy").load({ plugins = { "vim-dadbod-ui" } })
        end)
        if #vim.api.nvim_get_runtime_file("autoload/db_ui.vim", false) == 0 then
          return false, "vim-dadbod-ui is not on the runtimepath"
        end
        if vim.fn.maparg("<Plug>(DBUI_Redraw)", "n") == "" and vim.fn.exists("*db_ui#open") == 0 then
          return false, "dadbod-ui offers no redraw action"
        end
        return true
      end),
    },
    { name = "Add a Connection...", cmd = A.ex("IdeDbAdd"), rtxt = "<leader>Da" },
    { name = "Close the Explorer", cmd = A.ex("DBUIToggle", { plugin = "vim-dadbod-ui" }), rtxt = "<leader>DD" },
  },
}

for _, section in ipairs(editor) do
  if section.name ~= "Database" then
    items[#items + 1] = section
  end
end

return require("kebab.keys").humanise(items)
