-- Writing a file without the write being able to abort the caller.
--
-- `vim.fn.writefile` raises E482 ("Can't create file ...") rather than
-- returning -1, and no caller wrapped it -- so a build file in a read-only
-- checkout, a full disk, or a store whose directory could not be created
-- raised mid-flow: the dependency was reported as added, the scaffold stopped
-- without calling `done`, and the user saw a stack trace instead of a reason.
local M = {}

---Write `lines` to `path`, creating parent directories.
---@param path string
---@param lines string[]
---@param flags? string passed to writefile ("b" to keep the bytes exactly)
---@return boolean ok, string|nil err
function M.write_lines(path, lines, flags)
  local dir = vim.fn.fnamemodify(path, ":h")
  local made = pcall(vim.fn.mkdir, dir, "p")
  if not made and vim.fn.isdirectory(dir) == 0 then
    return false, ("could not create %s"):format(dir)
  end
  local ok, err = pcall(vim.fn.writefile, lines, path, flags or "")
  if not ok then
    -- E482 carries the reason; the Vim prefix is noise to a user.
    return false, ("could not write %s: %s"):format(path, tostring(err):gsub("^Vim[^:]*:", ""))
  end
  return true
end

---Read `path` as a list of lines.
---@param path string
---@param flags? string
---@return string[]|nil lines, string|nil err
function M.read_lines(path, flags)
  local ok, lines = pcall(vim.fn.readfile, path, flags or "")
  if not ok or type(lines) ~= "table" then
    return nil, "could not read " .. path
  end
  return lines
end

return M
