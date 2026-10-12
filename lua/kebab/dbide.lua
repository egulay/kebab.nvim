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
  -- The rows pane carries the connection too, so the pager keys work from
  -- either pane: pressing ]p where the rows are is the obvious thing to do.
  vim.b[buf].db = jdbc.dadbod_url(c.url)
  vim.b[buf].kebab_db_name = c.name
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbout"
  M.bind_pager(buf)
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

-- One pager per connection. A page flip has to re-run the statement -- the
-- cursor is not held open between requests -- so the statement is kept here
-- rather than re-read from the editor buffer, which the user may have edited
-- in the meantime. Pressing next must page the query whose rows are on screen.
local PAGES = {}

---Rows per page.
function M.page_size()
  local n = tonumber(vim.g.kebab_db_page_size)
  if n and n >= 1 then
    return math.floor(n)
  end
  return 100
end

---The pager state for a connection, if a statement has been run.
---@param url string
function M.pager(url)
  return PAGES[url]
end

---Pull the footer the runner appends, and the lines without it.
---@param lines string[]
---@return string[] rows, table|nil info { offset, shown, more }
function M.split_footer(lines)
  local rows, info = {}, nil
  for _, line in ipairs(lines or {}) do
    local offset, shown, more = line:match("^%-%- kebab%-page offset=(%d+) shown=(%d+) more=([01])$")
    if offset then
      info = { offset = tonumber(offset), shown = tonumber(shown), more = more == "1" }
    else
      rows[#rows + 1] = line
    end
  end
  return rows, info
end

---The pager line shown above the rows.
---@param c kebab.DbConnection
---@param info table|nil
---@return string
function M.pager_line(c, info)
  if not info then
    return ("-- %s"):format(c.name)
  end
  local size = M.page_size()
  local page = math.floor(info.offset / size) + 1
  local first = info.shown > 0 and info.offset + 1 or info.offset
  local last = info.offset + info.shown
  local total = info.more and "more" or tostring(last)
  return ("-- %s · rows %d-%d of %s · page %d · ]p next  [p prev  [P first  R refresh")
    :format(c.name, first, last, total, page)
end

---Run `sql` and show its first page.
---@param c kebab.DbConnection
---@param sql string
function M.run(c, sql)
  PAGES[c.url] = { sql = sql, offset = 0 }
  return M.fetch(c)
end

---Fetch the current page of the current statement.
---@param c kebab.DbConnection
function M.fetch(c)
  local pager = PAGES[c.url]
  if not pager then
    return false, "nothing has been run on this connection yet"
  end
  db.ensure_credentials(c.url)
  local arg = ("%d:%d"):format(pager.offset, M.page_size())
  local lines, err = jdbc.run(c.url, "page", { args = { arg }, stdin = pager.sql, timeout = 300000 })
  if not lines then
    -- A script cannot be paged -- which statement's rows would it be? -- so
    -- run it whole rather than refusing. Same for anything else the pager
    -- cannot do: the rows matter more than the pager.
    if tostring(err):find("paging needs a single statement", 1, true) then
      local whole, werr = db.query(c, pager.sql)
      if not whole then
        return M.failed(c, werr)
      end
      PAGES[c.url] = nil
      M.show_rows(c, vim.list_extend({ ("-- %s · not paged (several statements)"):format(c.name), "" }, whole))
      return true
    end
    return M.failed(c, err)
  end
  local rows, info = M.split_footer(lines)
  pager.info = info
  local header = { M.pager_line(c, info), "" }
  M.show_rows(c, vim.list_extend(header, rows))
  return true
end

---Report a failed statement where the rows would have been.
function M.failed(c, err)
  M.show_rows(c, vim.split(("-- %s · failed\n-- %s"):format(c.name, tostring(err)), "\n"))
  vim.notify(tostring(err), vim.log.levels.ERROR)
  return false, err
end

---Move by `delta` pages. Refuses to walk off either end, and says so rather
---than silently redrawing the same page.
---@param delta number
function M.turn_page(delta)
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  if not c then
    return vim.notify("No connection here", vim.log.levels.WARN)
  end
  local pager = PAGES[c.url]
  if not pager then
    return vim.notify("Nothing has been run yet", vim.log.levels.WARN)
  end
  local size = M.page_size()
  if delta > 0 and pager.info and not pager.info.more then
    return vim.notify("Already on the last page", vim.log.levels.INFO)
  end
  local target = pager.offset + delta * size
  if target < 0 then
    if pager.offset == 0 then
      return vim.notify("Already on the first page", vim.log.levels.INFO)
    end
    target = 0
  end
  pager.offset = target
  M.fetch(c)
end

---Back to the first page.
function M.first_page()
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  local pager = c and PAGES[c.url]
  if not pager then
    return vim.notify("Nothing has been run yet", vim.log.levels.WARN)
  end
  pager.offset = 0
  M.fetch(c)
end

---Re-run the current statement, same page.
function M.refresh()
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  local pager = c and PAGES[c.url]
  if not pager then
    return vim.notify("Nothing has been run yet", vim.log.levels.WARN)
  end
  M.fetch(c)
end

---Open a table the way double clicking one in a database IDE does: its select
---in the statement pane, its first page of rows underneath, cursor left in the
---statement so the next thing you type edits the query.
---
---The select carries no LIMIT: the page size is the grid's business, and a
---statement the user is shown should be the one they would have written.
---@param c kebab.DbConnection
---@param table_name string
function M.open_table(c, table_name)
  local sql = db.preview_sql(c.url, table_name)
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
  local ok, err = M.run(c, sql)
  local editor = M.layout(c).editor
  if editor and vim.api.nvim_win_is_valid(editor) then
    vim.api.nvim_set_current_win(editor)
  end
  return ok, err
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

---Paging keys, on both panes.
---
---`]p`/`[p` rather than something with <leader>: the whole of <leader>d* is
---the debugger's and <leader>D* is already the database menu, and a pager is
---pressed far too often to live three keys deep.
---@param buf integer
function M.bind_pager(buf)
  local keys = {
    ["]p"] = { function() M.turn_page(1) end, "Next page" },
    ["[p"] = { function() M.turn_page(-1) end, "Previous page" },
    ["[P"] = { function() M.first_page() end, "First page" },
    ["R"] = { function() M.refresh() end, "Re-run this page" },
  }
  for lhs, spec in pairs(keys) do
    vim.keymap.set("n", lhs, spec[1], { buffer = buf, desc = spec[2] })
  end
end

---Buffer-local keys for the statement pane.
---@param buf integer
function M.bind_editor(buf)
  M.bind_pager(buf)
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

---Run the whole buffer, however many statements it holds.
function M.run_all()
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  if not c then
    return vim.notify("This buffer has no connection (<leader>Dc attaches one)", vim.log.levels.WARN)
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  if vim.trim(text) == "" then
    return vim.notify("Nothing to run", vim.log.levels.WARN)
  end
  return M.run(c, text)
end

---Commands, so every one of these is reachable from the menu, from `:` and
---from a keymap -- and so the menu sweep can check it points at something
---real. A menu entry built on a bare closure is invisible to that sweep.
function M.setup()
  local commands = {
    IdeDbRun = { M.run_current, "Run the statement under the cursor" },
    IdeDbRunAll = { M.run_all, "Run every statement in this buffer" },
    IdeDbNextPage = { function() M.turn_page(1) end, "Next page of rows" },
    IdeDbPrevPage = { function() M.turn_page(-1) end, "Previous page of rows" },
    IdeDbFirstPage = { M.first_page, "First page of rows" },
    IdeDbRefreshPage = { M.refresh, "Re-run the current page" },
  }
  for name, spec in pairs(commands) do
    vim.api.nvim_create_user_command(name, function()
      spec[1]()
    end, { desc = spec[2] })
  end
end

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
