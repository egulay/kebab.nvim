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
local function screen_at(win, line, col)
  local pos = vim.api.nvim_win_get_position(win)
  return pos[1] + line, pos[2] + col
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
    -- The nodes are named by what they are, not by where they sit: a
    -- connection line, the Tables group, the first table under it.
    local names = {
      connection = "󰆼",
      tables = "Tables",
      table = "^%s+▸  ",
    }
    for name, pattern in pairs(names) do
      local line = line_matching(tree, pattern)
      if line then
        local row, col = screen_at(tree, line, 6)
        out[name] = { row = row, col = col }
      end
    end
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
        local word = vim.trim(text):match("^(%a[%w%-]*)")
        if word then
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

---Keep the file current while the editor runs.
---@param path string
function M.publish(path)
  local timer = vim.uv.new_timer()
  timer:start(300, 300, vim.schedule_wrap(function()
    local lines = {}
    for name, at in pairs(M.collect()) do
      lines[#lines + 1] = ("%s %d %d"):format(name, at.row, at.col)
    end
    table.sort(lines)
    pcall(vim.fn.writefile, lines, path)
  end))
  return timer
end

return M
