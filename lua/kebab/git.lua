-- Git operations the tree menu needs and neo-tree does not provide.
--
-- Split out of menus/tree.lua so the logic can be tested against a real
-- repository without a neo-tree window and a selected node: the menu resolves
-- which path the user clicked, this decides what reverting it means.
local M = {}

---Run git in `dir` and return its stdout lines, or nil plus the error output.
function M.run(dir, args)
  if vim.fn.executable("git") == 0 then
    return nil, "git is not installed"
  end
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out, "\n")
  end
  return out
end

---Run git and return its stdout as raw bytes.
---
---`systemlist` splits on newlines and rewrites NUL, which is exactly what the
---`-z` status format needs preserved -- and a filename may itself contain a
---newline. vim.system hands back the bytes untouched.
---@return string|nil stdout, string|nil err
function M.run_raw(dir, args)
  if vim.fn.executable("git") == 0 then
    return nil, "git is not installed"
  end
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = false }):wait(60000)
  if res.code ~= 0 then
    local err = vim.trim(res.stderr or "")
    return nil, err ~= "" and err or vim.trim(res.stdout or "")
  end
  return res.stdout or "", nil
end

---A pathspec that means exactly this path.
---
---Without the magic prefix git reads `*`, `?` and `[...]` in the path as glob
---metacharacters, so a SvelteKit route like `src/routes/[slug]` is a pathspec
---pattern rather than a directory name.
---@param path string
function M.literal(path)
  return ":(literal)" .. path
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

  -- `-z` is not an optimisation. The default format *quotes* any path with a
  -- non-ASCII byte and escapes it C-style ("sub/caf\303\251.txt"), and
  -- stripping only the quotes leaves a filename that does not exist -- so the
  -- revert silently skipped every such file while still deleting the others.
  -- The -z format emits raw bytes, NUL-separated, with no quoting at all.
  local raw, err = M.run_raw(dir, { "status", "--porcelain", "-z", "--", M.literal(path) })
  if not raw then
    return nil, "git status failed: " .. tostring(err)
  end

  local fields = {}
  for field in tostring(raw):gmatch("([^%z]*)%z") do
    fields[#fields + 1] = field
  end

  local plan = { root = root, path = path, modified = {}, untracked = {}, renamed = {} }
  local i = 1
  while i <= #fields do
    local entry = fields[i]
    i = i + 1
    if entry ~= "" then
      local code, rel = entry:sub(1, 2), entry:sub(4)
      -- A rename or copy spends two fields: the new path, then the old one.
      if code:sub(1, 1) == "R" or code:sub(1, 1) == "C" then
        local from = fields[i]
        i = i + 1
        -- Reverting a rename means restoring the old name and removing the new
        -- one. Putting the *new* name in `modified` could never work: it is
        -- what `git checkout HEAD --` is asked for, and HEAD has never heard
        -- of it -- "pathspec did not match any file(s) known to git", which
        -- then reported the whole revert as failed.
        if type(from) == "string" and from ~= "" then
          plan.modified[#plan.modified + 1] = from
          plan.renamed[#plan.renamed + 1] = { from = from, to = rel }
        else
          plan.modified[#plan.modified + 1] = rel
        end
      elseif code == "??" then
        plan.untracked[#plan.untracked + 1] = root .. "/" .. rel
      else
        plan.modified[#plan.modified + 1] = rel
      end
    end
  end
  return plan
end

---How many files an untracked entry really covers.
---
---`git status` collapses an untracked directory into a single `?? dir/` entry,
---so counting entries can understate a recursive delete by orders of
---magnitude -- and that count is the only thing the confirmation shows.
---@param path string
function M.untracked_file_count(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return 1
  end
  if stat.type ~= "directory" then
    return 1
  end
  local n = 0
  local function walk(dir)
    local fd = vim.uv.fs_scandir(dir)
    if not fd then
      n = n + 1
      return
    end
    while true do
      local name, typ = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if typ == "directory" then
        walk(dir .. "/" .. name)
      else
        n = n + 1
      end
    end
  end
  walk(path)
  return n
end

---Human-readable summary of a plan, for the confirmation prompt.
function M.describe_plan(plan)
  local parts = {}
  if #plan.modified > 0 then
    parts[#parts + 1] = ("discard changes in %d tracked file(s)"):format(#plan.modified)
  end
  if plan.renamed and #plan.renamed > 0 then
    parts[#parts + 1] = ("undo %d rename(s)"):format(#plan.renamed)
  end
  if #plan.untracked > 0 then
    local files, dirs = 0, 0
    for _, abs in ipairs(plan.untracked) do
      local stat = vim.uv.fs_stat(abs)
      if stat and stat.type == "directory" then
        dirs = dirs + 1
      end
      files = files + M.untracked_file_count(abs)
    end
    local text = ("DELETE %d untracked file(s)"):format(files)
    if dirs > 0 then
      -- say so: the user is approving a recursive delete
      text = text .. (" in %d new director%s"):format(dirs, dirs == 1 and "y" or "ies")
    end
    parts[#parts + 1] = text
  end
  return table.concat(parts, " and ")
end

---Carry out a plan. Returns ok, list of what failed.
---
---Order matters, and so does stopping. Restoring tracked files is reversible;
---deleting untracked ones is not. Doing the deletions anyway after a failed
---checkout destroyed new work while leaving the modifications the user asked
---to discard -- so a restore failure now cancels the deletions.
---
---Each path is checked out on its own, too: one pathspec git cannot match
---(a staged rename's new name, say) used to abort the whole batch, so nothing
---at all was restored.
function M.apply_revert(plan)
  local failed = {}
  for _, rel in ipairs(plan.modified) do
    local out, err = M.run(plan.root, { "checkout", "HEAD", "--", M.literal(rel) })
    if not out then
      failed[#failed + 1] = ("git checkout %s: %s"):format(rel, tostring(err))
    end
  end

  -- A rename's new name is a staged addition, so deleting the file is not
  -- enough -- the index entry has to go too, or the rename is half-reverted.
  for _, rename in ipairs(plan.renamed or {}) do
    local out, err = M.run(plan.root, { "rm", "-f", "--quiet", "--", M.literal(rename.to) })
    if not out then
      failed[#failed + 1] = ("git rm %s: %s"):format(rename.to, tostring(err))
    end
  end

  if #failed > 0 and #plan.untracked > 0 then
    failed[#failed + 1] = ("%d untracked file(s) were NOT deleted, because restoring the tracked files failed"):format(
      #plan.untracked
    )
    return false, failed
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
  return #plan.modified == 0 and #plan.untracked == 0 and #(plan.renamed or {}) == 0
end

return M
