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

---A window the statement pane may take over: not the tree, not the rows pane,
---and not one pinned against having its buffer replaced.
local function plain_win()
  local tree = M.tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local pinned = vim.wo[w].winfixbuf
    if w ~= tree and not pinned and not vim.b[b][EDITOR_VAR] and not vim.b[b][OUTPUT_VAR] then
      return w
    end
  end
  return nil
end

---Stop anything replacing this window's buffer.
---
---Clicking a tab in the bufferline loads that buffer into the focused window.
---With the data source tree or the rows grid focused that scrambled the
---layout -- the tree window showing a Go file, and no way back. `winfixbuf`
---makes the attempt fail loudly instead.
---@param win integer
local function pin(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].winfixbuf = true
    end)
  end
end

---Pin the explorer, whenever it is open.
function M.pin_tree()
  pin(M.tree_win())
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
---
---Deterministic on purpose. The first version focused "some window that is not
---the tree" and ran `:edit` in it, which fails in a window holding a special
---buffer -- and the failure is silent, so the code carried on and applied the
---statement pane's settings to *neo-tree's* buffer: a window showing the file
---tree with filetype sql, the data source tree gone, and the statement open
---twice. Measured in a real terminal with two files already open.
---
---So: reuse our own window if it is still there, otherwise open the file with
---the window command itself (`vsplit <path>`, not `vsplit` then `edit`), and
---then *check* that the window really holds that file.
---@param c kebab.DbConnection
---@return integer|nil win, string|nil err
function M.editor(c)
  local path = M.editor_path(c)
  if vim.fn.filereadable(path) == 0 then
    local wrote, werr = require("kebab.fs").write_lines(path, { ("-- %s"):format(c.name), "" })
    if not wrote then
      return nil, werr
    end
  end
  local esc = vim.fn.fnameescape(path)
  local want = vim.fn.fnamemodify(path, ":p")

  local function holds_it(win)
    return win
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == want
  end

  -- already open: reuse it
  local win = window_with(EDITOR_VAR)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    if not holds_it(win) then
      pcall(vim.cmd, "edit " .. esc)
    end
  else
    -- a window we may take over, and only if it holds an ordinary file
    local host = plain_win()
    if host and vim.bo[vim.api.nvim_win_get_buf(host)].buftype ~= "" then
      host = nil
    end
    if host then
      vim.api.nvim_set_current_win(host)
      pcall(vim.cmd, "edit " .. esc)
    else
      local tree = M.tree_win()
      if tree and vim.api.nvim_win_is_valid(tree) then
        vim.api.nvim_set_current_win(tree)
        pcall(vim.cmd, "rightbelow vsplit " .. esc)
      else
        pcall(vim.cmd, "vsplit " .. esc)
      end
    end
  end

  -- and verify, because every branch above can fail silently
  win = vim.api.nvim_get_current_win()
  if not holds_it(win) then
    local ok = pcall(vim.cmd, "botright vsplit " .. esc)
    win = vim.api.nvim_get_current_win()
    if not ok or not holds_it(win) then
      return nil, "could not open " .. path
    end
  end

  local buf = vim.api.nvim_win_get_buf(win)
  vim.b[buf][EDITOR_VAR] = true
  vim.bo[buf].filetype = "sql"
  db.attach(c, buf)
  M.bind_editor(buf)
  return win
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
  M.bind_rows(buf)
  local out = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(out, buf)
  pin(out)
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
  return win
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
---
---Two shapes, because there are two ways to page: `kebab-cursor` from a result
---set held open across requests (what a database IDE does), and `kebab-page`
---from the LIMIT/OFFSET and cursor-skip fallbacks.
---@param lines string[]
---@return string[] rows, table|nil info { offset?, shown, more, total?, kind }
function M.split_footer(lines)
  local rows, info = {}, nil
  for _, line in ipairs(lines or {}) do
    local shown, total, more = line:match("^%-%- kebab%-cursor shown=(%d+) total=(%d+) more=([01])")
    if shown then
      info = {
        kind = "cursor",
        shown = tonumber(shown),
        total = tonumber(total),
        more = more == "1",
      }
    else
      local offset, pshown, pmore = line:match("^%-%- kebab%-page offset=(%d+) shown=(%d+) more=([01])$")
      if offset then
        info = {
          kind = "page",
          offset = tonumber(offset),
          shown = tonumber(pshown),
          more = pmore == "1",
        }
      else
        rows[#rows + 1] = line
      end
    end
  end
  return rows, info
end

---The buttons on the rows pane, in order. Clickable, and each with a single
---key, because the grid is read-only so plain letters are free there.
---
---A pager is pressed constantly. `Space D n` -- spacebar, Shift+D, n -- is
---three keystrokes with a shift in the middle to turn a page, which is
---indefensible for the most-used control in the pane, and was said so in
---plain terms. These are one keypress, or one click.
function M.buttons()
  return {
    { key = "n", label = "next", desc = "Next page", action = function() M.turn_page(1) end },
    { key = "p", label = "prev", desc = "Previous page", action = function() M.turn_page(-1) end },
    { key = "f", label = "first", desc = "First page", action = function() M.first_page() end },
    { key = "r", label = "re-run", desc = "Re-run this page", action = function() M.refresh() end },
  }
end

---The pager lines shown above the rows: where you are, then the buttons.
---
---Built to fit the pane it is shown in, because a terminal is whatever size
---the person made it. At 200 columns everything is there; at 80 the hint after
---the buttons goes; narrower still, the labels go and the keys remain. The
---buttons never go -- they are the control.
---@param c kebab.DbConnection
---@param info table|nil
---@param width? number columns available; the rows window's width by default
---@return string where, string bar, table spans column ranges, 1-based inclusive
function M.pager_line(c, info, width)
  width = width or (function()
    local win = window_with(OUTPUT_VAR)
    return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
  end)()

  local buttons = M.buttons()
  -- widest first, narrowest last; the first that fits wins
  local layouts = {
    { labels = true, hint = true, gap = "  " },
    { labels = true, hint = false, gap = "  " },
    { labels = false, hint = false, gap = "  " },
    { labels = false, hint = false, gap = "" },
  }
  local bar, spans
  for _, layout in ipairs(layouts) do
    local text, got = "-- ", {}
    for i, b in ipairs(buttons) do
      local label = layout.labels and ("[ %s %s ]"):format(b.key, b.label) or ("[ %s ]"):format(b.key)
      got[#got + 1] = { from = #text + 1, to = #text + #label, key = b.key }
      text = text .. label .. (i < #buttons and layout.gap or "")
    end
    if layout.hint then
      text = text .. ("   run: %s"):format(require("kebab.keys").human("<C-CR>"))
    end
    bar, spans = text, got
    if #text <= width then
      break
    end
  end

  if not info then
    return ("-- %s"):format(c.name), bar, spans
  end
  local size = M.page_size()
  local offset = info.offset or 0
  local page = math.floor(offset / size) + 1
  local first = info.shown > 0 and offset + 1 or offset
  local last = offset + info.shown
  local total = info.more and "more" or tostring(last)
  -- Where the rows came from is worth saying: "held" means the statement ran
  -- once and this is the next batch off the same result set, which is the only
  -- mode that stays consistent while someone else is writing to the table.
  local source = ({ cursor = "held", server = "re-queried", client = "skipped" })[info.kind or ""]
  local where = ("-- %s · rows %d-%d of %s · page %d%s"):format(
    c.name, first, last, total, page, source and (" · " .. source) or "")
  if #where > width then
    -- the name and the provenance are the first things worth losing
    where = ("-- rows %d-%d of %s · page %d"):format(first, last, total, page)
  end
  return where, bar, spans
end

---Run `sql` and show its first page.
---@param c kebab.DbConnection
---@param sql string
function M.run(c, sql)
  -- A new statement replaces the result set, so nothing from the last one is
  -- kept: the warm process closes its cursor when any other request arrives.
  PAGES[c.url] = { sql = sql, offset = 0, pages = {}, fetched = 0, cursor_open = false }
  return M.fetch(c)
end

-- How a page was obtained, in the order they are preferred.
--
--   cursor  the statement ran once and the result set is held open in the warm
--           process; each page is the next batch off it. What a database IDE
--           does, and the only one that is consistent under concurrent writes
--           and does not re-execute the query per page.
--   server  the statement is re-run wrapped in the dialect's LIMIT/OFFSET.
--           Used when there is no warm process to hold a cursor.
--   client  the statement is re-run whole and rows are skipped on the cursor.
--           Used when the dialect has no OFFSET clause this layer knows.
--
---Fetch the current page.
---
---A page already fetched comes from `pager.pages`, not from the database: that
---is what makes going back instant, and -- with a held cursor -- it is the
---only way back at all, since a forward-only result set cannot be rewound.
---@param c kebab.DbConnection
function M.fetch(c)
  local pager = PAGES[c.url]
  if not pager then
    return false, "nothing has been run on this connection yet"
  end
  db.ensure_credentials(c.url)
  local size = M.page_size()
  local index = math.floor(pager.offset / size) + 1

  -- already fetched: show it again without asking the database
  local cached = pager.pages and pager.pages[index]
  if cached then
    pager.info = cached.info
    M.render(c, cached.rows, cached.info)
    return true
  end

  local lines, err, kind

  -- 1. the next batch from a result set held open in the warm process
  if pager.cursor_open and index == (pager.fetched or 0) + 1 then
    lines, err = jdbc.run(c.url, "cursor", { args = { ("next:%d"):format(size) }, timeout = 300000 })
    kind = lines and "cursor" or nil
  elseif index == 1 then
    lines, err = jdbc.run(c.url, "cursor", { args = { ("open:%d"):format(size) }, stdin = pager.sql, timeout = 300000 })
    kind = lines and "cursor" or nil
  end

  -- 2. the server's own LIMIT/OFFSET, when there is no cursor to hold
  if not lines then
    local paged = db.page_sql(c.url, pager.sql, pager.offset, size + 1)
    if paged then
      lines, err = jdbc.run(c.url, "page", { args = { ("0:%d"):format(size) }, stdin = paged, timeout = 300000 })
      kind = lines and "server" or nil
    end
  end

  -- 3. skipping on the cursor: dialect-free, slowest, always correct
  if not lines then
    local first_err = err
    lines, err = jdbc.run(c.url, "page", {
      args = { ("%d:%d"):format(pager.offset, size) },
      stdin = pager.sql,
      timeout = 300000,
    })
    kind = lines and "client" or nil
    if not lines then
      if tostring(first_err):find("paging needs a single statement", 1, true)
        or tostring(err):find("paging needs a single statement", 1, true) then
        -- A script has no single result set to page. Run it whole rather than
        -- refusing: the rows matter more than the pager.
        local whole, werr = db.query(c, pager.sql)
        if not whole then
          return M.failed(c, werr)
        end
        PAGES[c.url] = nil
        M.show_rows(c, vim.list_extend({ ("-- %s · not paged (several statements)"):format(c.name), "" }, whole))
        return true
      end
      return M.failed(c, first_err or err)
    end
  end

  local rows, info = M.split_footer(lines)
  info = info or { shown = #rows, more = false }
  info.kind = kind
  info.offset = pager.offset
  pager.info = info
  pager.pages = pager.pages or {}
  pager.pages[index] = { rows = rows, info = info }
  pager.fetched = math.max(pager.fetched or 0, index)
  pager.cursor_open = kind == "cursor" and info.more or false
  M.render(c, rows, info)
  return true
end

---Put a page on screen, with the button bar on line 2.
function M.render(c, rows, info)
  local where, bar, spans = M.pager_line(c, info)
  local win = M.show_rows(c, vim.list_extend({ where, bar, "" }, rows))
  if win then
    -- where each button sits, so a click can be mapped to one
    vim.b[vim.api.nvim_win_get_buf(win)].kebab_db_spans = spans
  end
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
  M.pin_tree()
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
    return vim.notify(("This buffer has no connection — press %s to attach one")
      :format(require("kebab.keys").human("<leader>Dc")), vim.log.levels.WARN)
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
    ["<leader>Dr"] = { function() M.run_current() end, "Run the statement" },
    -- dadbod-ui binds <leader>S in a sql buffer once it is loaded, which is
    -- exactly when this pane exists -- and its execute opens a result window
    -- of its own, so pressing it here would leave two. Ours is set after the
    -- filetype is, so ours wins; it is not *advertised* anywhere, because
    -- outside these two panes the same key is snacks' scratch-buffer picker.
    ["<leader>S"] = { function() M.run_current() end, "Run the statement" },
    ["<leader>Dn"] = { function() M.turn_page(1) end, "Next page of rows" },
    ["<leader>Db"] = { function() M.turn_page(-1) end, "Previous page of rows" },
    ["<leader>Df"] = { function() M.first_page() end, "First page of rows" },
    ["<leader>DR"] = { function() M.refresh() end, "Re-run this page" },
  }
  for lhs, spec in pairs(keys) do
    vim.keymap.set("n", lhs, spec[1], { buffer = buf, desc = spec[2] })
  end
  -- Ctrl+Enter in insert mode as well, so a query can be run without first
  -- leaving the mode you typed it in. That is what the muscle memory expects.
  for _, lhs in ipairs({ "<C-CR>", "<C-S-CR>" }) do
    vim.keymap.set({ "n", "i" }, lhs, function()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.cmd("stopinsert")
      end
      M.run_current()
    end, { buffer = buf, desc = "Run the statement" })
  end
end

---The rows pane gets single keys and a clickable bar.
---
---Only here: the grid is read-only, so `n`, `p`, `f` and `r` are free -- there
---is nothing to paste into, nothing to replace, and no search to continue. In
---the statement pane those letters are editing commands and must stay that
---way, which is why the leader sequence exists at all.
---@param buf integer
function M.bind_rows(buf)
  for _, b in ipairs(M.buttons()) do
    vim.keymap.set("n", b.key, b.action, { buffer = buf, desc = b.desc })
  end
  -- A click on a button runs it; a click anywhere else behaves like a click.
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    local spans = vim.b[buf].kebab_db_spans
    if pos.line == 2 and type(spans) == "table" then
      for _, span in ipairs(spans) do
        if pos.column >= span.from and pos.column <= span.to then
          for _, b in ipairs(M.buttons()) do
            if b.key == span.key then
              return b.action()
            end
          end
        end
      end
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "n", false)
  end, { buffer = buf, desc = "Click a pager button, or move the cursor" })
end

---Buffer-local keys for the statement pane.---Buffer-local keys for the statement pane.
---@param buf integer
function M.bind_editor(buf)
  -- bind_pager already binds Run and the pager, buffer-locally, so they win
  -- over the global <leader>S (dadbod's own exec, which opens a result window
  -- of its own and would leave two).
  M.bind_pager(buf)
end

-- --------------------------------------------------------------- the tree

---Run the whole buffer, however many statements it holds.
function M.run_all()
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  if not c then
    return vim.notify(("This buffer has no connection — press %s to attach one")
      :format(require("kebab.keys").human("<leader>Dc")), vim.log.levels.WARN)
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
    IdeDbStructure = { function() M.structure_prompt() end, "How a table is built: columns, keys, indexes" },
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

-- ------------------------------------------------------------- structure
--
-- The half of a database IDE that is not the data. Sitting down with somebody
-- else's database means asking what the columns are, which is the key, and how
-- the tables are joined -- before any query gets written.

---Split the runner's sections. Pure, so the shape is tested directly.
---@param lines string[]
---@return table sections
function M.parse_structure(lines)
  local out = { columns = {}, key = {}, foreign = {}, referenced = {}, indexes = {} }
  local section
  local names = {
    ["-- columns"] = "columns",
    ["-- primary key"] = "key",
    ["-- foreign keys"] = "foreign",
    ["-- referenced by"] = "referenced",
    ["-- indexes"] = "indexes",
  }
  for _, line in ipairs(lines or {}) do
    local header = names[vim.trim(line)]
    if header then
      section = header
    elseif section and vim.trim(line) ~= "" then
      local fields = vim.split(line, "\t", { plain = true })
      if section == "key" then
        for name in line:gmatch("[^,%s]+") do
          out.key[#out.key + 1] = name
        end
      elseif section == "columns" then
        out.columns[#out.columns + 1] = {
          name = fields[1],
          type = fields[2],
          null = fields[3],
          default = fields[4] ~= "" and fields[4] or nil,
          pk = fields[5] == "pk",
          auto = fields[6] == "auto",
        }
      elseif section == "foreign" then
        out.foreign[#out.foreign + 1] =
          { column = fields[1], table = fields[2], target = fields[3], name = fields[4] }
      elseif section == "referenced" then
        out.referenced[#out.referenced + 1] =
          { table = fields[1], column = fields[2], target = fields[3], name = fields[4] }
      elseif section == "indexes" then
        out.indexes[#out.indexes + 1] =
          { name = fields[1], unique = fields[2] == "unique", columns = fields[3] }
      end
    end
  end
  return out
end

---Lay the structure out so it can be read aloud to someone.
---@param table_name string
---@param parsed table
---@return string[]
function M.render_structure(table_name, parsed)
  local out = { ("-- %s"):format(table_name), "" }
  local function pad(text, to)
    text = tostring(text or "")
    return text .. string.rep(" ", math.max(0, to - vim.fn.strdisplaywidth(text)))
  end

  if #parsed.columns > 0 then
    local w1, w2 = 0, 0
    for _, col in ipairs(parsed.columns) do
      w1 = math.max(w1, vim.fn.strdisplaywidth(col.name or ""))
      w2 = math.max(w2, vim.fn.strdisplaywidth(col.type or ""))
    end
    out[#out + 1] = "columns"
    for _, col in ipairs(parsed.columns) do
      local notes = {}
      if col.pk then
        notes[#notes + 1] = "pk"
      end
      if col.auto then
        notes[#notes + 1] = "auto"
      end
      if col.default then
        notes[#notes + 1] = "default " .. col.default
      end
      out[#out + 1] = ("  %s  %s  %s%s"):format(
        pad(col.name, w1), pad(col.type, w2), pad(col.null, 8),
        #notes > 0 and ("  " .. table.concat(notes, ", ")) or "")
    end
    out[#out + 1] = ""
  end

  out[#out + 1] = "primary key"
  out[#out + 1] = "  " .. (#parsed.key > 0 and table.concat(parsed.key, ", ") or "none")
  out[#out + 1] = ""

  out[#out + 1] = "foreign keys"
  if #parsed.foreign == 0 then
    out[#out + 1] = "  none"
  end
  for _, fk in ipairs(parsed.foreign) do
    out[#out + 1] = ("  %s → %s.%s"):format(fk.column, fk.table, fk.target)
  end
  out[#out + 1] = ""

  out[#out + 1] = "referenced by"
  if #parsed.referenced == 0 then
    out[#out + 1] = "  none"
  end
  for _, fk in ipairs(parsed.referenced) do
    out[#out + 1] = ("  %s.%s → %s"):format(fk.table, fk.column, fk.target)
  end
  out[#out + 1] = ""

  out[#out + 1] = "indexes"
  if #parsed.indexes == 0 then
    out[#out + 1] = "  none"
  end
  for _, index in ipairs(parsed.indexes) do
    out[#out + 1] = ("  %s%s  (%s)"):format(index.name, index.unique and "  unique" or "", index.columns)
  end
  -- the padding is for alignment, not for the end of a line
  for i, line in ipairs(out) do
    out[i] = (line:gsub("%s+$", ""))
  end
  return out
end

---Ask which table, then show how it is built.
---
---The connection comes from the buffer when there is one, so in the SQL panes
---it asks only for the table.
function M.structure_prompt()
  local attached = db.attached()
  local c = attached and (db.connection(attached.name) or attached) or nil
  local function go(conn)
    local tables, err = db.tables(conn)
    if not tables then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    if #tables == 0 then
      return vim.notify(("%s has no tables"):format(conn.name), vim.log.levels.INFO)
    end
    vim.ui.select(tables, { prompt = ("Structure of which table in %s?"):format(conn.name) }, function(choice)
      if choice then
        M.show_structure(conn, choice)
      end
    end)
  end
  if c then
    return go(c)
  end
  db.pick("Database", go)
end

---Show a table's structure where the rows go.
---@param c kebab.DbConnection
---@param table_name string
function M.show_structure(c, table_name)
  local lines, err = db.structure(c, table_name)
  if not lines then
    return M.failed(c, err)
  end
  M.layout(c)
  local rendered = M.render_structure(table_name, M.parse_structure(lines))
  -- no pager: this is one answer, not a page of rows
  PAGES[c.url] = nil
  M.show_rows(c, rendered)
  return true
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

  -- "New query" is dadbod-ui's own node, and its action opens a buffer in
  -- whichever window dadbod-ui feels like using -- which is how a three-pane
  -- layout ends up with the statement open twice and the tree gone. Give it
  -- the statement pane instead, which is where a new query belongs.
  local line = vim.trim(((lines[row] or ""):gsub("^[^%w_]*", "")))
  if line == "New query" then
    local layout = M.layout(c)
    if layout.editor then
      local buf = vim.api.nvim_win_get_buf(layout.editor)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("-- %s"):format(c.name), "", "" })
      pcall(vim.api.nvim_win_set_cursor, layout.editor, { 2, 0 })
      vim.api.nvim_set_current_win(layout.editor)
      vim.cmd("startinsert")
    end
    return
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
