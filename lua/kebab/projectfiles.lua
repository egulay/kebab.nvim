-- Project-level files a graphical IDE generates for you -- BACKLOG.md item 5:
-- .gitignore for the language in hand, a Dockerfile, a CI workflow,
-- .editorconfig.
--
-- Distinct from kebab.templates, which creates a *source* file where you are and
-- asks what to call it. These have fixed names and belong at the project root,
-- so they are a separate list and a separate command -- mixing them would mean
-- a picker offering "Java class" and ".editorconfig" side by side.
local M = {}

local registry = require("kebab.registry")

---The project root for `dir`, or `dir` when it is not inside a project.
---@param dir string
function M.root_of(dir)
  local _, marker = registry.find_project(dir)
  if marker then
    return vim.fn.fnamemodify(marker, ":h")
  end
  return (dir:gsub("/+$", ""))
end

---Project files on offer for a directory.
---
---A generator declared with `kinds` is only offered in a project of that kind,
---so a Go project is not offered a Maven Dockerfile. One with no `kinds` -- an
---.editorconfig, say -- is always offered.
---@param dir string
---@return table[]
function M.available(dir)
  local kind = registry.kind_of(M.root_of(dir))
  local out = {}
  for _, f in ipairs(registry.collect("project_files")) do
    if f.kinds == nil or (kind and vim.tbl_contains(f.kinds, kind)) then
      out[#out + 1] = f
    end
  end
  return out
end

---@param name string
---@param dir string
function M.by_name(name, dir)
  local needle = name:lower()
  for _, f in ipairs(M.available(dir)) do
    if f.name:lower() == needle or f.file:lower() == needle then
      return f
    end
  end
  for _, f in ipairs(M.available(dir)) do
    if f.name:lower():find(needle, 1, true) then
      return f
    end
  end
  return nil
end

---Write a project file. Returns ok, path_or_err.
---@param generator table
---@param dir string
---@param opts? { open?: boolean, overwrite?: boolean }
function M.create(generator, dir, opts)
  opts = opts or {}
  if not generator or not generator.file then
    return false, "Nothing to generate"
  end
  local root = M.root_of(dir)
  local path = root .. "/" .. generator.file

  if vim.uv.fs_stat(path) and not opts.overwrite then
    return false, vim.fn.fnamemodify(path, ":~:.") .. " already exists"
  end

  local ctx = {
    path = path,
    root = root,
    project = vim.fn.fnamemodify(root, ":t"),
    kind = registry.kind_of(root),
  }
  local lines = type(generator.render) == "function" and generator.render(ctx) or generator.lines
  if type(lines) ~= "table" then
    return false, "Generator " .. tostring(generator.name) .. " produced nothing"
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  if opts.open ~= false then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
  return true, path
end

---Pick a project file to generate.
---@param opts? { dir?: string }
function M.pick(opts)
  opts = opts or {}
  local dir = opts.dir or vim.fn.getcwd()
  local generators = M.available(dir)
  if #generators == 0 then
    return vim.notify("No project files to generate here", vim.log.levels.WARN)
  end
  local root = M.root_of(dir)
  vim.ui.select(generators, {
    prompt = "Generate project file (" .. vim.fn.fnamemodify(root, ":t") .. ")",
    format_item = function(g)
      local exists = vim.uv.fs_stat(root .. "/" .. g.file) and "  [exists]" or ""
      return ("%-34s %s%s"):format(g.name, g.file, exists)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, result = M.create(choice, dir)
    if ok then
      return vim.notify("Created " .. vim.fn.fnamemodify(result, ":~:."))
    end
    -- Offer to replace rather than making the user delete it first, but never
    -- overwrite a project file without asking.
    if tostring(result):match("already exists") then
      vim.ui.select({ "No", "Yes" }, { prompt = result .. ". Overwrite?" }, function(answer)
        if answer ~= "Yes" then
          return vim.notify("Left " .. choice.file .. " alone")
        end
        local ok2, result2 = M.create(choice, dir, { overwrite = true })
        vim.notify(ok2 and ("Replaced " .. vim.fn.fnamemodify(result2, ":~:.")) or result2,
          ok2 and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
      return
    end
    vim.notify(result, vim.log.levels.ERROR)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("IdeProjectFile", function(cmd)
    if cmd.args == "" then
      return M.pick()
    end
    local dir = vim.fn.getcwd()
    local gen = M.by_name(cmd.args, dir)
    if not gen then
      local names = vim.tbl_map(function(g) return g.file end, M.available(dir))
      return vim.notify(
        ("No generator matching %q (have: %s)"):format(cmd.args, table.concat(names, ", ")),
        vim.log.levels.WARN)
    end
    local ok, result = M.create(gen, dir, { overwrite = cmd.bang })
    vim.notify(ok and ("Created " .. vim.fn.fnamemodify(result, ":~:.")) or result,
      ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, {
    nargs = "?",
    bang = true,
    desc = "Generate a project file (.gitignore, Dockerfile, CI workflow, …)",
    complete = function(lead)
      local out = {}
      for _, g in ipairs(M.available(vim.fn.getcwd())) do
        if g.file:lower():find(lead:lower(), 1, true) then
          out[#out + 1] = g.file
        end
      end
      return out
    end,
  })
end

return M
