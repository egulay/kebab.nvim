-- New-file templates -- BACKLOG.md item 3.
--
-- "New Java class" in a graphical IDE fills in the package line from the
-- directory you right-clicked. That is the part worth having: typing
-- `package com.example.thing.service;` by hand is both tedious and the thing
-- you get wrong after moving a file.
--
-- Templates are declared per language in lua/kebab/languages/, so this file
-- names no language.
local M = {}

local registry = require("kebab.registry")

-- Source roots whose remainder is the package, longest first so
-- src/test/java wins over src.
local SOURCE_ROOTS = {
  "src/main/java",
  "src/test/java",
  "src/main/kotlin",
  "src/test/kotlin",
  "src/main/groovy",
  "src/test/groovy",
}

---The package a file in `dir` belongs to, from the directory layout.
---
---Pure, and tested as such: this is the part that a graphical IDE gets right
---and that is tedious to type.
---@param dir string
---@return string package dotted package, or "" when dir is not under a source root
function M.package_for(dir)
  local path = vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")
  for _, root in ipairs(SOURCE_ROOTS) do
    -- match the root as a whole path segment, so "mysrc/main/java" does not
    local prefix = "/" .. root .. "/"
    local at = path:find(prefix, 1, true)
    if at then
      local rest = path:sub(at + #prefix)
      if rest == "" then
        return ""
      end
      return (rest:gsub("/", "."))
    end
    -- the source root itself, with nothing below it
    if path:sub(-#("/" .. root)) == ("/" .. root) then
      return ""
    end
  end
  return ""
end

---Templates available for a directory, and optionally a filetype.
---@param opts? { filetype?: string }
---@return table[]
function M.available(opts)
  opts = opts or {}
  local out = {}
  for _, t in ipairs(registry.templates()) do
    local ok = true
    if opts.filetype and t.filetypes and not vim.tbl_contains(t.filetypes, opts.filetype) then
      ok = false
    end
    if ok then
      out[#out + 1] = t
    end
  end
  return out
end

---Where a template writes, which is not always the directory you are in: a
---test template belongs under src/test/java even when invoked from
---src/main/java. Declared per template as `target_dir`.
---@param template table
---@param dir string
---@return string
function M.target_dir(template, dir)
  if type(template.target_dir) == "function" then
    local redirected = template.target_dir(dir)
    if type(redirected) == "string" and redirected ~= "" then
      return redirected
    end
  end
  return dir
end

---Swap a Maven/Gradle main source root for the matching test root, keeping the
---package path. Pure, so it is tested directly.
---@param dir string
---@return string
function M.test_dir_for(dir)
  local path = vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")
  for main, test in pairs({
    ["/src/main/java/"] = "/src/test/java/",
    ["/src/main/kotlin/"] = "/src/test/kotlin/",
  }) do
    local at = path:find(main, 1, true)
    if at then
      return path:sub(1, at - 1) .. test .. path:sub(at + #main)
    end
    -- the source root itself, with no package below it
    local bare = main:sub(1, -2)
    if path:sub(-#bare) == bare then
      return path:sub(1, #path - #bare) .. test:sub(1, -2)
    end
  end
  return dir
end

---The path a template would write to.
---@param template table
---@param dir string
---@param name string what the user typed
---Is `path` inside `dir` once `..` has been resolved?
---@param dir string
---@param path string
local function contained(dir, path)
  local base = vim.fs.normalize(dir):gsub("/+$", "")
  local full = vim.fs.normalize(path)
  return full == base or full:sub(1, #base + 1) == base .. "/"
end

---@param template table
---@param dir string
---@param name string
---@return string|nil path, string|nil err
function M.path_for(template, dir, name)
  -- Some templates decide their own path from the answer: a SvelteKit route
  -- directory becomes `<answer>/+page.svelte`, not `<answer>.svelte`.
  if type(template.relative_path) == "function" then
    local rel = template.relative_path(name)
    return (dir:gsub("/+$", "")) .. "/" .. (rel:gsub("^/+", ""))
  end
  -- An extension the user typed wins: "Thing.java" and "Thing" both work.
  local ext = template.extension
  if ext and ext ~= "" and not name:match("%." .. vim.pesc(ext) .. "$") then
    name = name .. "." .. ext
  end
  -- An absolute name would otherwise be pasted on: "/d" .. "/" .. "/tmp/x".
  if name:match("^/") then
    return nil, "a file name cannot be an absolute path: " .. name
  end
  local path = (dir:gsub("/+$", "")) .. "/" .. name
  -- `../../../../outside/Pwned` wrote the file outside the project and
  -- reported success, with an un-normalised path and a nonsense package line.
  -- A subdirectory is fine; leaving the directory is not.
  if not contained(dir, path) then
    return nil, ("%q would write outside %s"):format(name, dir)
  end
  return vim.fs.normalize(path)
end

---Render a template's contents.
---@param template table
---@param ctx table { path, dir, name, package, project_root, answers }
---@return string[] lines
function M.render(template, ctx)
  if type(template.render) == "function" then
    return template.render(ctx)
  end
  return template.lines or {}
end

---Build the context a template is rendered with.
---@param template table
---@param dir string
---@param name string
---@param answers? table
function M.context(template, dir, name, answers)
  dir = M.target_dir(template, dir)
  local path, perr = M.path_for(template, dir, name)
  if not path then
    return nil, perr
  end
  local basename = vim.fn.fnamemodify(path, ":t")
  local stem = basename:gsub("%.[^.]+$", "")
  local _, marker = registry.find_project(dir)
  return {
    path = path,
    dir = dir,
    file = basename,
    name = stem,
    package = M.package_for(dir),
    project_root = marker and vim.fn.fnamemodify(marker, ":h") or dir,
    answers = answers or {},
  }
end

---Write the file and open it. Returns ok, err_or_path.
---@param template table
---@param dir string
---@param name string
---@param opts? { answers?: table, open?: boolean }
function M.create(template, dir, name, opts)
  opts = opts or {}
  if not template then
    return false, "No template given"
  end
  if name == nil or vim.trim(name) == "" then
    -- a template whose prompt says "blank for here" has to accept blank
    if not template.blank_name_ok then
      return false, "A file name is required"
    end
    name = ""
  end

  local ctx, cerr = M.context(template, dir, vim.trim(name or ""), opts.answers)
  if not ctx then
    return false, cerr
  end
  if vim.uv.fs_stat(ctx.path) then
    return false, ctx.path .. " already exists"
  end

  local lines = M.render(template, ctx)
  if type(lines) ~= "table" then
    return false, "Template " .. tostring(template.name) .. " produced nothing"
  end

  local wrote, werr = require("kebab.fs").write_lines(ctx.path, lines)
  if not wrote then
    return false, werr
  end

  if opts.open ~= false then
    vim.cmd("edit " .. vim.fn.fnameescape(ctx.path))
  end
  return true, ctx.path
end

---Interactive: pick a template, then name the file.
---@param opts? { dir?: string, filetype?: string }
function M.pick(opts)
  opts = opts or {}
  local dir = opts.dir or vim.fn.expand("%:p:h")
  if dir == "" or not vim.uv.fs_stat(dir) then
    dir = vim.fn.getcwd()
  end

  local templates = M.available({ filetype = opts.filetype })
  if #templates == 0 then
    return vim.notify("No file templates are registered", vim.log.levels.WARN)
  end

  vim.ui.select(templates, {
    prompt = "New file from template",
    format_item = function(t)
      local pkg = M.package_for(dir)
      if t.extension == "java" and pkg ~= "" then
        return ("%s  (%s)"):format(t.name, pkg)
      end
      return t.name
    end,
  }, function(template)
    if not template then
      return
    end
    local function finish(answers)
      local default
      if type(template.default_name) == "function" then
        default = template.default_name(vim.fn.expand("%:t:r"))
      end
      vim.ui.input({ prompt = (template.prompt or "Name") .. ": ", default = default }, function(name)
        if not name or vim.trim(name) == "" then
          return
        end
        local ok, result = M.create(template, dir, name, { answers = answers })
        if not ok then
          return vim.notify(result, vim.log.levels.ERROR)
        end
        vim.notify("Created " .. vim.fn.fnamemodify(result, ":~:."))
      end)
    end

    -- a template may ask its own questions first
    local prompts = template.prompts or {}
    local answers = {}
    local function step(i)
      local p = prompts[i]
      if not p then
        return finish(answers)
      end
      if p.kind == "select" then
        vim.ui.select(p.choices, { prompt = p.prompt }, function(choice)
          if not choice then return end
          answers[p.name] = choice
          step(i + 1)
        end)
      else
        vim.ui.input({ prompt = p.prompt, default = p.default }, function(value)
          if value == nil then return end
          answers[p.name] = value == "" and p.default or value
          step(i + 1)
        end)
      end
    end
    step(1)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("IdeNewFile", function()
    M.pick()
  end, { desc = "New file from a template" })
end

return M
