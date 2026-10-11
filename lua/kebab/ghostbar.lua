-- The Ghost Mode indicator.
--
-- An *activity* light, not a status light. It appears because something else
-- has just touched the project -- an agent writing a file -- names that file,
-- and goes away again once things have been quiet for a few seconds.
--
-- It is deliberately not shown merely because following is armed. A badge that
-- sits there permanently says nothing about whether an agent is doing
-- anything, which is the only question it exists to answer.
--
-- It is deliberately inert: not focusable, no mappings, no autocmds of its
-- own on the editor's buffers. Closing the window by hand is allowed and the
-- animation notices.
local M = {}

local STATE = {
  active = false, -- show() was called and hide() has not been
  win = nil,
  buf = nil,
  timer = nil,
  frame = 1,
  activity = nil, -- the file most recently followed
  activity_at = 0,
  count = 0,
}

M.SPINNER = { "󰊠  ", " 󰊠 ", "  󰊠", " 󰊠 " }
M.HL = "KebabGhostMode"

---How the indicator behaves. `vim.g.kebab_follow_indicator = false` turns it off.
function M.config()
  local g = vim.g.kebab_follow_indicator
  local cfg = {
    enabled = g ~= false,
    interval_ms = 120,
    -- how long a filename stays on the panel after it was followed
    activity_ms = 2500,
    -- how long the panel stays up after the last change. Past this it hides
    -- itself: nothing is happening, so there is nothing to report.
    idle_ms = 5000,
    title = "Ghost Mode",
  }
  if type(g) == "table" then
    cfg = vim.tbl_extend("force", cfg, g)
  end
  if type(vim.g.kebab_follow_spinner) == "table" and #vim.g.kebab_follow_spinner > 0 then
    M.SPINNER = vim.g.kebab_follow_spinner
  end
  return cfg
end

---The one line the panel shows.
---@return string
function M.line()
  local cfg = M.config()
  local spin = M.SPINNER[((STATE.frame - 1) % #M.SPINNER) + 1]
  local parts = { spin, cfg.title }
  if STATE.activity and (vim.uv.now() - STATE.activity_at) < cfg.activity_ms then
    parts[#parts + 1] = "· " .. STATE.activity
  elseif STATE.count > 0 then
    parts[#parts + 1] = ("· %d change%s"):format(STATE.count, STATE.count == 1 and "" or "s")
  end
  return " " .. table.concat(parts, " ") .. " "
end

local function visible()
  return STATE.win ~= nil and vim.api.nvim_win_is_valid(STATE.win)
end

---Place the window in the bottom-right corner, sized to its text.
---
---Only ever opens one while the panel is meant to be up: render() must not be
---able to resurrect it after hide().
local function place(text)
  if not STATE.active then
    return
  end
  local width = vim.fn.strdisplaywidth(text)
  local row = math.max(0, vim.o.lines - 2)
  local col = math.max(0, vim.o.columns - 1)
  if visible() then
    pcall(vim.api.nvim_win_set_config, STATE.win, {
      relative = "editor",
      anchor = "SE",
      row = row,
      col = col,
      width = width,
      height = 1,
    })
    return
  end
  STATE.win = vim.api.nvim_open_win(STATE.buf, false, {
    relative = "editor",
    anchor = "SE",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })
  vim.wo[STATE.win].winhighlight = ("Normal:%s,FloatBorder:%s"):format(M.HL, M.HL)
end

---Redraw the panel. Safe to call when it is not showing.
function M.render()
  if not STATE.buf or not vim.api.nvim_buf_is_valid(STATE.buf) then
    return false
  end
  local text = M.line()
  vim.bo[STATE.buf].modifiable = true
  vim.api.nvim_buf_set_lines(STATE.buf, 0, -1, false, { text })
  vim.bo[STATE.buf].modifiable = false
  place(text)
  return true
end

local function stop_timer()
  if STATE.timer then
    pcall(function()
      STATE.timer:stop()
      if not STATE.timer:is_closing() then
        STATE.timer:close()
      end
    end)
    STATE.timer = nil
  end
end

---Show the indicator and start the animation.
function M.show()
  local cfg = M.config()
  if not cfg.enabled then
    return false
  end
  if not STATE.buf or not vim.api.nvim_buf_is_valid(STATE.buf) then
    STATE.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[STATE.buf].bufhidden = "hide"
    vim.bo[STATE.buf].filetype = "kebabghost"
  end
  -- a colour of its own, but only if the theme has not defined one
  if vim.fn.hlexists(M.HL) == 0 or next(vim.api.nvim_get_hl(0, { name = M.HL })) == nil then
    vim.api.nvim_set_hl(0, M.HL, { link = "DiagnosticInfo", default = true })
  end
  STATE.active = true
  M.render()

  stop_timer()
  STATE.timer = vim.uv.new_timer()
  STATE.timer:start(
    cfg.interval_ms,
    cfg.interval_ms,
    vim.schedule_wrap(function()
      -- Following may have stopped, or the window been closed by hand.
      if not require("kebab.follow").running() then
        return M.hide()
      end
      -- Quiet for long enough: nothing is happening, so stop saying anything.
      local idle = cfg.idle_ms or 5000
      if idle > 0 and STATE.activity_at > 0 and (vim.uv.now() - STATE.activity_at) >= idle then
        return M.hide()
      end
      STATE.frame = STATE.frame + 1
      M.render()
    end)
  )
  return true
end

---Hide the indicator and stop the animation.
function M.hide()
  STATE.active = false
  stop_timer()
  if visible() then
    pcall(vim.api.nvim_win_close, STATE.win, true)
  end
  -- Blank the buffer too, so state().text reports what is on screen rather
  -- than whatever was last on it.
  if STATE.buf and vim.api.nvim_buf_is_valid(STATE.buf) then
    pcall(function()
      vim.bo[STATE.buf].modifiable = true
      vim.api.nvim_buf_set_lines(STATE.buf, 0, -1, false, { "" })
      vim.bo[STATE.buf].modifiable = false
    end)
  end
  STATE.win = nil
  STATE.activity = nil
  STATE.count = 0
  STATE.frame = 1
  return true
end

---Note that `path` was just followed, so the panel can name it.
---@param path string
---Note that `path` was just touched by something outside the editor.
---
---This is what puts the panel on screen. Following being armed does not.
---@param path string
function M.activity(path)
  STATE.count = STATE.count + 1
  STATE.activity = vim.fn.fnamemodify(path, ":t")
  STATE.activity_at = vim.uv.now()
  if not STATE.active then
    M.show()
  elseif visible() then
    M.render()
  end
  return STATE.activity
end

---For tests and :IdeFollowStatus.
function M.state()
  return {
    active = STATE.active,
    showing = visible(),
    animating = STATE.timer ~= nil,
    frame = STATE.frame,
    activity = STATE.activity,
    count = STATE.count,
    text = (STATE.buf and vim.api.nvim_buf_is_valid(STATE.buf))
        and (vim.api.nvim_buf_get_lines(STATE.buf, 0, 1, false)[1] or "")
      or "",
  }
end

return M
