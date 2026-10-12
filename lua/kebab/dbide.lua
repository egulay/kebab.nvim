-- The three-pane SQL IDE: tree on the left, the statement top right, its rows
-- under it.
--
-- This is the layout a dedicated database IDE opens with, and double clicking
-- a table is how you look at data in one. dadbod-ui gives the tree and nothing
-- else: a double click on a table there expands it to a "List" child that you
-- then have to click, and the result lands in whatever window dadbod feels
-- like using. So the tree stays, and this module owns opening a table.
--
--   +-----------+--------------------------+
--   | explorer  | the statement (editable) |
--   |           +--------------------------+
--   |           | its rows                 |
--   +-----------+--------------------------+
--
-- The statement pane is a real file under stdpath("data"), not a scratch
-- buffer, for the same reason `<leader>Dq` consoles are: you edit the select
-- that was written for you, and losing that on a window close would be
-- indefensible.
local M = {}

local db = require("kebab.db")
local jdbc = require("kebab.jdbc")

local EDITOR_VAR = "kebab_db_editor"
local OUTPUT_VAR = "kebab_db_output"

---Height of the rows pane, as a fraction of the editor column.
function M.output_fraction()
  local n = tonumber(vim.g.kebab_db_output_fraction)
  if n and n > 0.1 and n < 0.9 then
    return n
  end
  return 0.6
end

-- ------------------------------------------------------------------ windows

---@param var string
---@return integer|nil win
local function window_with(var)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b][var] then
      return w
    end
  end
  return nil
end

---The explorer window, if it is open.
function M.tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "dbui" then
      return w
    end
  end
  return nil
end

---A window that is neither the tree nor one of ours: where the editor goes.
local function plain_win()
  local tree = M.tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if w ~= tree and not vim.b[b][EDITOR_VAR] and not vim.b[b][OUTPUT_VAR] then
      return w
    end
  end
  return nil
end

-- ------------------------------------------------------------------ buffers

---The statement file for a connection. One per connection, reused, so
---double clicking three tables in a row does not leave three buffers.
---@param c kebab.DbConnection
---@return string path
function M.editor_path(c)
  return ("%s/%s.sql"):format(db.sql_dir(), (c.name:gsub("[^%w%-_]", "_")))
end

---Put the statement pane on screen and return its window.
---@param c kebab.DbConnection
function M.editor(c)
  local win = window_with(EDITOR_VAR)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  else
    local host = plain_win()
    if host then
      vim.api.nvim_set_current_win(host)
    else
      -- only the tree is open: make room to its right
      local tree = M.tree_win()
      if tree then
        vim.api.nvim_set_current_win(tree)
        vim.cmd("rightbelow vsplit")
      else
        vim.cmd("vsplit")
      end
    end
  end

  local path = M.editor_path(c)
  if vim.fn.filereadable(path) == 0 then
    local wrote, werr = require("kebab.fs").write_lines(path, { ("-- %s"):format(c.name), "" })
    if not wrote then
      return nil, werr
    end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf][EDITOR_VAR] = true
  vim.bo[buf].filetype = "sql"
  db.attach(c, buf)
  M.bind_editor(buf)
  return vim.api.nvim_get_current_win()
end

---The rows pane for a connection, below the statement.
---@param c kebab.DbConnection
function M.output(c)
  local win = window_with(OUTPUT_VAR)
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  local editor = window_with(EDITOR_VAR)
  if not editor then
    return nil
  end
  vim.api.nvim_set_current_win(editor)
  vim.cmd("belowright split")
  local buf = vim.api.nvim_create_buf(false, true)
  local name = ("kebab-db://%s/rows"):format(c.name)
  if vim.fn.bufexists(name) == 1 then
    pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(name), { force = true })
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.b[buf][OUTPUT_VAR] = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbout"
  local out = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(out, buf)
  local total = vim.api.nvim_win_get_height(editor) + vim.api.nvim_win_get_height(out)
  vim.api.nvim_win_set_height(out, math.max(3, math.floor(total * M.output_fraction())))
  return out
end

---Replace the rows pane's contents.
---@param c kebab.DbConnection
---@param lines string[]
function M.show_rows(c, lines)
  local win = M.output(c)
  if not win then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  return true
end

-- ----------------------------------------------------------------- the flow

---Open a table the way double clicking one in a database IDE does: its select
---in the statement pane, its rows underneath, cursor left in the statement so
---the next thing you type edits the query.
---@param c kebab.DbConnection
---@param table_name string
function M.open_table(c, table_name)
  local sql = db.preview_sql(c.url, table_name, db.preview_limit())
  local layout = M.layout(c)
  if not layout.editor then
    return false, "could not open the statement pane"
  end
  local buf = vim.api.nvim_win_get_buf(layout.editor)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("-- %s"):format(c.name), sql, "" })
  pcall(vim.api.nvim_win_set_cursor, layout.editor, { 2, 0 })
  -- Saved, so the pane is a file you can come back to rather than a buffer
  -- with unsaved changes that refuses to be replaced by the next table.
  pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end)
  return M.run(c, sql)
end

---Run `sql` and put the result in the rows pane.
---@param c kebab.DbConnection
---@param sql string
function M.run(c, sql)
  local lines, err = db.query(c, sql)
  if not lines then
    M.show_rows(c, vim.split("-- " .. tostring(err), "\n"))
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return false, err
  end
  M.show_rows(c, lines)
  local editor = window_with(EDITOR_VAR)
  if editor and vim.api.nvim_win_is_valid(editor) then
    vim.api.nvim_set_current_win(editor)
  end
  return true
end

---The whole layout, created as needed.
---@param c kebab.DbConnection
---@return { tree: integer|nil, editor: integer|nil, output: integer|nil }
function M.layout(c)
  local editor = M.editor(c)
  local output = editor and M.output(c) or nil
  if editor and vim.api.nvim_win_is_valid(editor) then
    vim.api.nvim_set_current_win(editor)
  end
  return { tree = M.tree_win(), editor = editor, output = output }
end

---Run the statement under the cursor from the statement pane.
function M.run_current()
  local c = db.attached()
  if not c then
    return vim.notify("This buffer has no connection (<leader>Dc attaches one)", vim.log.levels.WARN)
  end
  local saved = db.connection(c.name)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local offset = 0
  for i = 1, row - 1 do
    offset = offset + #vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1] + 1
  end
  local statement = require("kebab.dbcomplete").statement_at(text, offset + col)
  if statement == nil or vim.trim(statement) == "" then
    statement = text
  end
  if vim.trim(statement) == "" then
    return vim.notify("Nothing to run", vim.log.levels.WARN)
  end
  return M.run(saved or c, statement)
end

---Buffer-local keys for the statement pane.
---@param buf integer
function M.bind_editor(buf)
  -- Buffer-local, so it wins over the global <leader>S (dadbod's own exec,
  -- which opens a result window of its own and would leave two).
  vim.keymap.set("n", "<leader>S", function()
    M.run_current()
  end, { buffer = buf, desc = "Run the statement under the cursor" })
  vim.keymap.set("n", "<C-CR>", function()
    M.run_current()
  end, { buffer = buf, desc = "Run the statement under the cursor" })
end

-- --------------------------------------------------------------- the tree

---The table name on a dadbod-ui tree line, or nil.
---
---Pure, so it is tested directly. The tree is drawn with icons and indentation
---(`      ▸  inventory.stock_item`), and rather than guess at the format the
---candidate is checked against the table list this layer already has for that
---connection -- which is also what stops "Saved queries (0)" or "New query"
---being mistaken for a table.
---@param line string
---@param tables string[]
---@return string|nil
function M.table_on_line(line, tables)
  local text = line
  -- strip everything that is not part of an identifier from the front: the
  -- indent, the expand arrow, and the icon, whatever glyphs those are
  text = text:gsub("^[^%w_]*", "")
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  for _, name in ipairs(tables or {}) do
    if name == text then
      return name
    end
  end
  return nil
end

---The connection a tree line belongs to: the nearest connection name at or
---above it. Names come from this layer's own store, so this does not depend
---on how the tree is drawn.
---@param lines string[]
---@param row integer 1-based
---@param names string[]
---@return string|nil
function M.connection_above(lines, row, names)
  for i = math.min(row, #lines), 1, -1 do
    local text = vim.trim((lines[i]:gsub("^[^%w_]*", "")))
    -- a connection line carries the name and may carry a status marker
    for _, name in ipairs(names or {}) do
      if text == name or text:match("^" .. vim.pesc(name) .. "%s") then
        return name
      end
    end
  end
  return nil
end

---What a double click in the tree should do.
---
---A table opens in the layout; anything else falls through to dadbod-ui's own
---action, which expands a node, starts a new query, and so on.
function M.click()
  local function fallback()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>(DBUI_SelectLine)", true, false, true), "mx", false)
  end
  if vim.bo.filetype ~= "dbui" then
    return fallback()
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local saved, err = db.connections()
  if err or #saved == 0 then
    return fallback()
  end
  local names = vim.tbl_map(function(c) return c.name end, saved)
  local name = M.connection_above(lines, row, names)
  if not name then
    return fallback()
  end
  local c = db.connection(name)
  if not c then
    return fallback()
  end
  -- The completion cache usually has the list already, which costs nothing.
  -- When it does not -- expanding a connection in the tree does not populate
  -- it -- ask the database, because falling back to dadbod-ui's expansion here
  -- is exactly the behaviour being replaced.
  local tables = require("kebab.dbcomplete").table_names(c.url)
  if #tables == 0 then
    tables = db.tables(c) or {}
  end
  local table_name = M.table_on_line(lines[row] or "", tables)
  if not table_name then
    return fallback()
  end
  M.open_table(c, table_name)
end

return M
