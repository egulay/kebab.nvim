-- Git operations the tree menu needs and neo-tree does not provide.
--
-- Split out of menus/tree.lua so the logic can be tested against a real
-- repository without a neo-tree window and a selected node: the menu resolves
-- which path the user clicked, this decides what reverting it means.
local M = {}

---Run git in `dir` and return its stdout lines, or nil plus the error output.
function M.run(dir, args)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out, "\n")
  end
  return out
end

---The repository root containing `dir`, or nil.
function M.toplevel(dir)
  local out = M.run(dir, { "rev-parse", "--show-toplevel" })
  return out and out[1] or nil
end

---What reverting `path` would actually do.
---
---`git checkout HEAD -- <path>` silently ignores untracked files, so reverting
---a newly added file -- or a directory containing one -- used to look like it
---did nothing. Splitting the porcelain status into tracked and untracked is
---what lets the caller delete the latter, which is what "revert" is taken to
---mean.
---@param path string file or directory
---@return table|nil plan { root, modified = {rel}, untracked = {abs}, path }
---@return string|nil err
function M.revert_plan(path)
  local stat = vim.uv.fs_stat(path)
  local isdir = stat and stat.type == "directory"
  local dir = isdir and path or vim.fn.fnamemodify(path, ":h")

  local root = M.toplevel(dir)
  if not root then
    return nil, "Not inside a git repository"
  end

  local status, err = M.run(dir, { "status", "--porcelain", "--", path })
  if not status then
    return nil, "git status failed: " .. tostring(err)
  end

  local plan = { root = root, path = path, modified = {}, untracked = {} }
  for _, line in ipairs(status) do
    if line ~= "" then
      local code, rel = line:sub(1, 2), line:sub(4)
      -- a rename reads "R  old -> new"; the new name is what exists on disk
      rel = rel:match("%s%->%s(.+)$") or rel
      rel = rel:gsub('^"(.*)"$', "%1")
      if code == "??" then
        plan.untracked[#plan.untracked + 1] = root .. "/" .. rel
      else
        plan.modified[#plan.modified + 1] = rel
      end
    end
  end
  return plan
end

---Human-readable summary of a plan, for the confirmation prompt.
function M.describe_plan(plan)
  local parts = {}
  if #plan.modified > 0 then
    parts[#parts + 1] = ("discard changes in %d tracked file(s)"):format(#plan.modified)
  end
  if #plan.untracked > 0 then
    parts[#parts + 1] = ("DELETE %d untracked file(s)"):format(#plan.untracked)
  end
  return table.concat(parts, " and ")
end

---Carry out a plan. Returns ok, list of what failed.
function M.apply_revert(plan)
  local failed = {}
  if #plan.modified > 0 then
    local args = { "checkout", "HEAD", "--" }
    vim.list_extend(args, plan.modified)
    local out, err = M.run(plan.root, args)
    if not out then
      failed[#failed + 1] = "git checkout: " .. tostring(err)
    end
  end
  for _, abs in ipairs(plan.untracked) do
    if vim.fn.delete(abs, "rf") ~= 0 then
      failed[#failed + 1] = abs
    end
  end
  return #failed == 0, failed
end

---True when `plan` would change nothing.
function M.is_empty(plan)
  return #plan.modified == 0 and #plan.untracked == 0
end

return M
