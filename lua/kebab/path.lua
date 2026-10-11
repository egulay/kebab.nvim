-- Expanding a path that came from outside the editor.
--
-- `vim.fn.expand()` is Vim's expansion, and Vim's expansion runs the shell for
-- anything in backticks: `vim.fn.expand("`touch /tmp/pwn`")` creates the file.
-- Every path this layer takes from an argument, a prompt or a config variable
-- used to go through it, so `kebab open '`cmd`'` executed `cmd` in the editor
-- process before any directory check.
--
-- `vim.fs.normalize()` does the part that is actually wanted -- `~` and `$VAR`
-- -- and never shells out.
local M = {}

---Expand `~` and environment variables in a path, without shell expansion.
---@param input any
---@return any
function M.expand(input)
  if type(input) ~= "string" or input == "" then
    return input
  end
  local ok, out = pcall(vim.fs.normalize, input)
  if not ok or type(out) ~= "string" or out == "" then
    return input
  end
  return out
end

---True when `input` would be run as a shell command by Vim's own expansion.
---
---Used to reject such a path outright where one is not expected, so a caller
---gets an error instead of a silently different path.
---@param input any
function M.is_shell_expansion(input)
  return type(input) == "string" and input:find("`") ~= nil
end

return M
