-- Tell the driver where things are on screen, so a click can be aimed rather
-- than guessed.
--
-- Hardcoded screen rows are why one fixture change -- a second table in the
-- test database -- broke five cases that had nothing to do with it: every node
-- below it moved down a line. This rewrites the file as the layout changes, so
-- `click_target` clicks where the thing is *now*.
--
-- Format, one per line: `<name> <screen row> <screen column>`, both 1-based,
-- which is what a terminal's mouse report uses.
local M = {}

---The window showing a buffer that satisfies `want`, or nil.
---@param want fun(buf: integer): boolean
local function window(want)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if want(vim.api.nvim_win_get_buf(w)) then
      return w
    end
  end
  return nil
end

local function tree_win()
  return window(function(b)
    return vim.bo[b].filetype == "dbui"
  end)
end

local function rows_win()
  return window(function(b)
    return vim.b[b].kebab_db_output == true
  end)
end

local function editor_win()
  return window(function(b)
    return vim.b[b].kebab_db_editor == true
  end)
end

---Screen position of a buffer line and column in a window. 1-based.
---
---`textoff` is the width of the window's gutter -- numbers, signs, folds. A
---click computed without it lands that many characters to the left of the
---intended text, which looked exactly like a button that did not work.
local function screen_at(win, line, col)
  local pos = vim.api.nvim_win_get_position(win)
  local info = vim.fn.getwininfo(win)[1]
  local gutter = info and info.textoff or 0
  return pos[1] + line, pos[2] + gutter + col
end

---The first line in `win` whose text matches `pattern`, 1-based, or nil.
local function line_matching(win, pattern)
  local buf = vim.api.nvim_win_get_buf(win)
  for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find(pattern) then
      return i
    end
  end
  return nil
end

---Every target this run can offer, by name.
---@return table<string, {row: integer, col: integer}>
function M.collect()
  local out = {}
  local tree = tree_win()
  if tree then
    -- Resolved through the layer's own functions rather than by pattern. A
    -- pattern for "a collapsed node" matched `▸ Saved queries (0)`, which sits
    -- above the tables, so the click expanded that and the case failed as
    -- though the double click were broken.
    local ok, dbide = pcall(require, "kebab.dbide")
    local saved = ok and (require("kebab.db").connections()) or {}
    local names = vim.tbl_map(function(c) return c.name end, saved)
    local buf = vim.api.nvim_win_get_buf(tree)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    for i, text in ipairs(lines) do
      local bare = vim.trim((text:gsub("^[^%w_]*", "")))
      -- the connection line: its name, with or without a status marker
      if not out.connection then
        for _, name in ipairs(names) do
          if bare == name or bare:match("^" .. vim.pesc(name) .. "%s") then
            local row, col = screen_at(tree, i, 6)
            out.connection = { row = row, col = col }
          end
        end
      end
      if not out.tables and bare:match("^Tables") then
        local row, col = screen_at(tree, i, 8)
        out.tables = { row = row, col = col }
      end
      -- a table: whatever the layer itself recognises as one on that line
      if not out.table and ok and #names > 0 then
        local owner = dbide.connection_above(lines, i, names)
        local c = owner and require("kebab.db").connection(owner)
        if c then
          local known = require("kebab.dbcomplete").table_names(c.url)
          if #known == 0 then
            known = require("kebab.db").tables(c) or {}
          end
          if dbide.table_on_line(text, known) then
            local row, col = screen_at(tree, i, 10)
            out.table = { row = row, col = col }
          end
        end
      end
    end
  end

  -- The middle of the ordinary editing window: where a user right-clicks when
  -- they want the editor menu and there is no file open yet. Resolved from the
  -- live layout rather than hardcoded, because the dashboard, a file and a
  -- three-pane database layout all put it somewhere different.
  local main = window(function(b)
    local ft = vim.bo[b].filetype
    return ft ~= "neo-tree" and ft ~= "dbui" and not vim.b[b].kebab_db_output
  end)
  if main and vim.api.nvim_win_get_config(main).relative == "" then
    local height = vim.api.nvim_win_get_height(main)
    local width = vim.api.nvim_win_get_width(main)
    local pos = vim.api.nvim_win_get_position(main)
    out.editor_area = {
      row = pos[1] + math.max(1, math.floor(height / 2)),
      col = pos[2] + math.max(1, math.floor(width / 2)),
    }
  end

  -- a node in the file tree, for the right-click menu there
  local filetree = window(function(b)
    return vim.bo[b].filetype == "neo-tree"
  end)
  if filetree then
    local line = line_matching(filetree, "%a") or 1
    local row, col = screen_at(filetree, math.max(line, 2), 4)
    out.tree_node = { row = row, col = col }
  end

  local editor = editor_win()
  if editor then
    local row, col = screen_at(editor, 1, 4)
    out.statement = { row = row, col = col }
  end

  local rows = rows_win()
  if rows then
    local buf = vim.api.nvim_win_get_buf(rows)
    -- the pager buttons, each at the middle of its own label
    for _, span in ipairs(vim.b[buf].kebab_db_spans or {}) do
      local middle = math.floor((span.from + span.to) / 2)
      local row, col = screen_at(rows, 2, middle)
      out["button_" .. span.key] = { row = row, col = col }
    end
    local row, col = screen_at(rows, 4, 4)
    out.rows = { row = row, col = col }
  end

  -- The tab bar is not a window, so its position cannot be read from one.
  -- nvim_eval_statusline renders it and says how wide it is, which is enough
  -- to find the column a given buffer's tab occupies.
  if vim.o.showtabline > 0 and vim.o.tabline ~= "" then
    local ok, rendered = pcall(vim.api.nvim_eval_statusline, vim.o.tabline, { use_tabline = true })
    if ok and rendered and rendered.str then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buflisted then
          local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
          if name ~= "" then
            local at = rendered.str:find(name, 1, true)
            if at then
              out["tab_" .. name] = { row = 1, col = at }
            end
          end
        end
      end
    end
  end

  -- The right-click menu is a floating window that draws its labels as
  -- virtual text, so the rows are found through the extmarks rather than the
  -- buffer lines, which are blank.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(w)
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunks = (mark[4] or {}).virt_text or {}
        local text = ""
        for _, chunk in ipairs(chunks) do
          text = text .. chunk[1]
        end
        -- The label only, slugged. Two traps in a row here: naming a target
        -- by the first word made "Run Statement" and "Run Whole Buffer"
        -- collide, and slugging the whole line folded in the shortcut printed
        -- after it ("run_statement_ctrl_enter"). The label is everything
        -- before the run of spaces that separates it from its key.
        local label = vim.trim(text):gsub("%s%s+.*$", "")
        local word = label:lower():gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
        if word ~= "" then
          -- mark[2] is the 0-based row inside the float; a bordered window
          -- draws its first row one line down from its own position
          local row, col = screen_at(w, mark[2] + 2, 4)
          out["menu_" .. word:lower()] = { row = row, col = col }
        end
      end
    end
  end
  return out
end

---Run `fn` once `want()` is true, instead of after a fixed delay.
---
---Two cases called `dbide.open_table` from a `defer_fn(7000)`, which assumes
---the editor has finished booting, loading lazy and opening db mode inside
---seven seconds. On a loaded machine -- a full suite run -- it has not, the
---panes were created and then torn down by the mode setup that followed, and
---the case failed 40 seconds later as "the editor never reported a target
---called 'statement'", which reads like a broken pane rather than a race.
---@param want fun(): boolean
---@param fn function
---@param budget_ms? integer how long to keep waiting (default 40s)
function M.when(want, fn, budget_ms)
  local waited, step = 0, 200
  local budget = budget_ms or 40000
  local timer = vim.uv.new_timer()
  timer:start(step, step, vim.schedule_wrap(function()
    waited = waited + step
    local ok, ready = pcall(want)
    if ok and ready then
      timer:stop()
      timer:close()
      return fn()
    end
    if waited >= budget then
      timer:stop()
      timer:close()
      -- Run it anyway: the case's own assertions are a better failure message
      -- than silence, and this is a test harness.
      return fn()
    end
  end))
  return timer
end

---Keep the file current while the editor runs.
---@param path string
function M.publish(path)
  local timer = vim.uv.new_timer()
  timer:start(300, 300, vim.schedule_wrap(function()
    local lines = {}
    -- One failing section must not take every target with it: an error here
    -- used to leave the file empty, and the case then failed as "the editor
    -- never reported a target called 'statement'" -- which reads like a
    -- missing pane rather than a broken collector.
    local ok, found = pcall(M.collect)
    if not ok then
      lines[#lines + 1] = "ERROR 0 0 " .. tostring(found):gsub("%s+", " ")
      found = {}
    end
    for name, at in pairs(found) do
      lines[#lines + 1] = ("%s %d %d"):format(name, at.row, at.col)
    end
    table.sort(lines)
    pcall(vim.fn.writefile, lines, path)
  end))
  return timer
end

return M
