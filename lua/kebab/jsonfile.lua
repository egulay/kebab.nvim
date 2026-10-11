-- Writing a JSON file this layer owns but a person is invited to hand-edit.
--
-- `vim.json.encode` emits one line, and a committed file wants to be readable,
-- so jq pretty-prints it where it is available. jq is optional, and
-- `vim.fn.system` raises E475 for a missing executable rather than setting
-- v:shell_error -- so the `shell_error ~= 0` fallback every caller wrote was
-- unreachable, and the write threw instead.
local M = {}

---Pretty-print an encoded JSON string into lines, falling back to the one-liner.
---@param encoded string
---@return string[] lines
function M.pretty(encoded)
  local lines = { encoded }
  if vim.fn.executable("jq") == 1 then
    local ran, out = pcall(vim.fn.system, { "jq", "." }, encoded)
    if ran and vim.v.shell_error == 0 and vim.trim(out) ~= "" then
      lines = vim.split(out, "\n")
    end
  end
  -- drop the trailing blank the split leaves behind
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

---True when `value` is a JSON array rather than an object.
---
---`type(x) == "table"` is not the check: an object decodes to a table too, so
---a `{ "configurations": { ... } }` slip read back as zero entries instead of
---being reported as malformed.
---@param value any
function M.is_array(value)
  return type(value) == "table" and vim.islist(value)
end

return M
