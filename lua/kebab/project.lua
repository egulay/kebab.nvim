-- Project create/open: the flows a graphical IDE puts on its welcome screen.
--
-- :IdeOpenProject   - pick any project under the usual roots and switch to it
-- :IdeNewProject    - scaffold a new project and open it
-- :IdeInitHere      - scaffold into the directory you are already in
-- :IdeCheatsheet    - open the keymap reference
--
-- Scaffolding is split in two on purpose. M.create() takes every answer up
-- front and prompts for nothing, so the `kebab` shell command and the tests can
-- drive it; M.new_project() is the wizard that collects those answers through
-- vim.ui and then calls it. Before the split there was only the wizard, which
-- meant nothing about project creation could be tested at all.
local M = {}

local uv = vim.uv

local DEFAULT_ROOTS = {
  "~/Projects",
  "~/src",
  "~/code",
  "~/dev",
}

---Where to look for projects. Overridable so the tests can point discovery at
---a scratch directory, and so a user with another layout is not stuck with it.
---vim.g.kebab_project_roots wins over $KEBAB_PROJECT_ROOTS (colon separated).
function M.roots()
  if type(vim.g.kebab_project_roots) == "table" then
    return vim.g.kebab_project_roots
  end
  local env = vim.env.KEBAB_PROJECT_ROOTS
  if env and env ~= "" then
    return vim.split(env, ":", { trimempty = true })
  end
  return DEFAULT_ROOTS
end

-- What counts as a project, and what kind it is, comes from
-- lua/kebab/languages/ via the registry. It used to be two hardcoded lists
-- here, which meant adding Go needed an edit in this file as well as in
-- plugins/mason.lua, plugins/extras.lua, plugins/run.lua and deps.lua.
local registry = require("kebab.registry")

local function is_project(dir)
  return registry.is_project(dir)
end

local function kind_of(dir)
  return registry.kind_of(dir) or "dir"
end

local function is_dir(path, scandir_type)
  if scandir_type == "directory" then
    return true
  end
  -- A symlink reports its own type here, and a broken one makes fs_stat return
  -- nil -- which used to be indexed straight away, so a single dangling link
  -- in ~/Projects took the whole project list down.
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

function M.discover()
  local found = {}
  local seen = {}
  for _, root in ipairs(M.roots()) do
    local path = require("kebab.path").expand(root)
    local fd = uv.fs_scandir(path)
    if fd then
      while true do
        local name, typ = uv.fs_scandir_next(fd)
        if not name then break end
        local full = path .. "/" .. name
        if is_dir(full, typ) and is_project(full) and not seen[full] then
          seen[full] = true
          found[#found + 1] = {
            path = full,
            name = name,
            root = vim.fn.fnamemodify(path, ":t"),
            kind = kind_of(full),
          }
        end
      end
    end
  end
  table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
  return found
end

-- Switch the editor to a project directory.
function M.open_dir(dir)
  if not uv.fs_stat(dir) then
    return vim.notify("No such directory: " .. dir, vim.log.levels.ERROR)
  end
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  -- let the tree reopen for the new root
  vim.g.ide_explorer_opened = false
  pcall(function()
    require("lazy").load({ plugins = { "neo-tree.nvim" } })
  end)
  vim.schedule(function()
    pcall(function()
      require("neo-tree.command").execute({ action = "show", dir = dir })
    end)
    vim.notify("Project: " .. vim.fn.fnamemodify(dir, ":t") .. "  (" .. dir .. ")")
  end)
end

function M.open_project()
  local projects = M.discover()
  if #projects == 0 then
    return vim.notify("No projects found under " .. table.concat(M.roots(), ", "), vim.log.levels.WARN)
  end
  vim.ui.select(projects, {
    prompt = "Open Project",
    format_item = function(p)
      return string.format("%-28s  %-8s  %s", p.name, p.kind, p.root)
    end,
  }, function(choice)
    if choice then
      M.open_dir(choice.path)
    end
  end)
end

-- ---------------------------------------------------------------- scaffolds
--
-- The project types are not listed here. Each language in
-- lua/kebab/languages/ declares the scaffolds it offers, and the registry
-- collects them, so a new language or framework is a new file rather than an
-- edit to this one. A user can add or override a type through
-- vim.g.kebab_languages without touching the repo.
--
-- `M.types` stays a plain list for everything that reads it -- the wizard, the
-- CLI, the tests -- so only where the list comes from has changed.

---Every project type that can be created, in language load order.
---@return table[]
function M.project_types()
  return registry.project_types()
end

---The type registered under `key`, or nil.
function M.type_by_key(key)
  for _, t in ipairs(registry.project_types()) do
    if t.key == key then
      return t
    end
  end
  return nil
end

---The keys of every registered type, for help text and shell completion.
function M.type_keys()
  return vim.tbl_map(function(t) return t.key end, registry.project_types())
end

---Executables a type needs that are not on PATH.
function M.missing_requirements(type_def)
  local missing = {}
  for _, exe in ipairs(type_def.requires or {}) do
    if vim.fn.executable(exe) == 0 then
      missing[#missing + 1] = exe
    end
  end
  return missing
end

---Create a project without asking anything.
---
---@param spec table { type, name, dest, answers?, open? }
---@param done? fun(ok:boolean, err:string|nil, dest:string|nil)
function M.create(spec, done)
  done = done or function() end

  local type_def = M.type_by_key(spec.type)
  if not type_def then
    local err = ("Unknown project type %q (have: %s)"):format(
      tostring(spec.type), table.concat(M.type_keys(), ", "))
    vim.notify(err, vim.log.levels.ERROR)
    return done(false, err)
  end

  local name = spec.name
  if not name or name == "" then
    local err = "A project name is required"
    vim.notify(err, vim.log.levels.ERROR)
    return done(false, err)
  end

  local dest = require("kebab.path").expand(spec.dest or (vim.fn.expand("~/Projects") .. "/" .. name))
  if uv.fs_stat(dest) and #vim.fn.readdir(dest) > 0 then
    local err = "Directory exists and is not empty: " .. dest
    vim.notify(err, vim.log.levels.ERROR)
    return done(false, err, dest)
  end

  local missing = M.missing_requirements(type_def)
  if #missing > 0 then
    local err = ("%s needs %s on PATH"):format(type_def.label, table.concat(missing, ", "))
    vim.notify(err, vim.log.levels.ERROR)
    return done(false, err, dest)
  end

  -- Fill in any answer the caller left out from the type's own defaults, so a
  -- non-interactive caller only has to supply what it wants to change.
  local answers = vim.deepcopy(spec.answers or {})
  local known = {}
  for _, p in ipairs(type_def.prompts or {}) do
    known[p.name] = true
    if answers[p.name] == nil then
      answers[p.name] = p.default
    end
  end

  -- `kebab new` passes any --name value straight through as an answer, which is
  -- what keeps the shell script free of per-language knowledge. The cost is
  -- that a typo would otherwise be swallowed in silence, so say something: a
  -- misspelt --deps on a Go project should not look like it worked.
  local unknown = {}
  for name in pairs(answers) do
    if not known[name] then
      unknown[#unknown + 1] = name
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    local accepted = vim.tbl_map(function(p) return p.name end, type_def.prompts or {})
    vim.notify(
      ("%s does not ask for %s%s"):format(
        type_def.label,
        table.concat(unknown, ", "),
        #accepted > 0 and (" (it asks for: " .. table.concat(accepted, ", ") .. ")") or " (it asks nothing)"),
      vim.log.levels.WARN)
  end

  vim.notify("Creating " .. type_def.label .. " in " .. dest)
  local ctx = { dest = dest, name = name, answers = answers, type = type_def }
  type_def.build(ctx, function(ok, err)
    if not ok then
      vim.notify("Project creation failed", vim.log.levels.ERROR)
      return done(false, err or "build failed", dest)
    end
    vim.notify("Created " .. name)
    if spec.open ~= false then
      M.open_dir(dest)
    end
    done(true, nil, dest)
  end)
end

-- --------------------------------------------------------------- the wizard

---Ask a type's prompts in order, then call cb(answers) -- or nothing if the
---user backs out.
local function ask(type_def, cb)
  local answers = {}
  local prompts = type_def.prompts or {}
  local function step(i)
    local p = prompts[i]
    if not p then
      return cb(answers)
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
        if value == "" then value = p.default end
        answers[p.name] = value
        step(i + 1)
      end)
    end
  end
  step(1)
end

local function pick_type(cb)
  vim.ui.select(registry.project_types(), {
    prompt = "Project type",
    format_item = function(t) return t.label end,
  }, function(choice)
    if choice then cb(choice) end
  end)
end

-- Full wizard: type -> name -> location -> the type's own questions.
function M.new_project()
  pick_type(function(type_def)
    vim.ui.input({ prompt = "Project name: " }, function(name)
      if not name or name == "" then return end
      -- ~/Projects is where this user keeps new work; note the capital P.
      local default_parent = vim.fn.expand("~/Projects")
      vim.ui.input({
        prompt = "Location: ",
        default = default_parent .. "/" .. name,
        completion = "dir",
      }, function(dest)
        if not dest or dest == "" then return end
        ask(type_def, function(answers)
          M.create({
            type = type_def.key,
            name = name,
            dest = require("kebab.path").expand(dest),
            answers = answers,
          })
        end)
      end)
    end)
  end)
end

-- a graphical editor style: you already made and opened the folder, now fill it in.
function M.init_here()
  local dest = vim.fn.getcwd()
  local existing = vim.fn.readdir(dest)
  local function go()
    pick_type(function(type_def)
      ask(type_def, function(answers)
        M.create({
          type = type_def.key,
          name = vim.fn.fnamemodify(dest, ":t"),
          dest = dest,
          answers = answers,
        })
      end)
    end)
  end
  if #existing > 0 then
    vim.ui.select({ "No", "Yes" }, {
      prompt = ("%s is not empty (%d entries). Scaffold into it anyway?")
        :format(vim.fn.fnamemodify(dest, ":t"), #existing),
    }, function(ans)
      if ans == "Yes" then go() end
    end)
  else
    go()
  end
end

-- The cheatsheet ships with this repo, so it is located on the runtimepath
-- rather than at an absolute path. The editor menu used to point at
-- ~/.config/nvim/IDE-CHEATSHEET.md, which has never existed; both entry points
-- now share this one implementation.
function M.open_cheatsheet()
  local f = vim.api.nvim_get_runtime_file("CHEATSHEET.md", false)[1]
  if not f then
    return vim.notify("CHEATSHEET.md not found on the runtimepath", vim.log.levels.WARN)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(f))
end

function M.setup()
  vim.api.nvim_create_user_command("IdeOpenProject", M.open_project, { desc = "Open a project" })
  vim.api.nvim_create_user_command("IdeNewProject", M.new_project, { desc = "Create a new project" })
  vim.api.nvim_create_user_command("IdeInitHere", M.init_here, { desc = "Scaffold a project into the current directory" })
  vim.api.nvim_create_user_command("IdeCheatsheet", M.open_cheatsheet, { desc = "Open the keymap cheatsheet" })
end

return M
