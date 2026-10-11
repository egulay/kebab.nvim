-- Per-project run configurations -- BACKLOG.md item 6.
--
-- The templates in lua/kebab/languages/ are generic: "maven: test" is the same
-- in every Maven project. What a graphical IDE also has is configurations that
-- belong to *this* project, with its arguments and its environment, committed
-- so the rest of the team gets them too.
--
-- They live in .kebab/run.json at the project root, in a format meant to be
-- read and edited by hand:
--
--   {
--     "configurations": [
--       {
--         "name": "api (local profile)",
--         "cmd": ["./mvnw"],
--         "args": ["spring-boot:run", "-Dspring-boot.run.profiles=local"],
--         "env": { "LOG_LEVEL": "debug" },
--         "cwd": "."
--       }
--     ]
--   }
--
-- They are exposed to overseer through a template *provider*, so they show up
-- in <leader>oo alongside everything else and follow you between projects
-- without a reload.
local M = {}

local registry = require("kebab.registry")

M.FILE = ".kebab/run.json"

---The project root for `dir`.
function M.root_of(dir)
  dir = dir or vim.fn.getcwd()
  local _, marker = registry.find_project(dir)
  if marker then
    return vim.fn.fnamemodify(marker, ":h")
  end
  return (dir:gsub("/+$", ""))
end

---Where the configurations live for a project.
function M.file(root)
  return M.root_of(root) .. "/" .. M.FILE
end

---Check one configuration. Returns ok, err.
---
---Reported rather than ignored: a typo in a committed file should say what is
---wrong, not silently drop the configuration someone else added.
---@param config any
---@param index? number
function M.validate(config, index)
  local where = index and ("configuration %d"):format(index) or "configuration"
  if type(config) ~= "table" then
    return false, where .. " is not an object"
  end
  if type(config.name) ~= "string" or config.name == "" then
    return false, where .. " needs a name"
  end
  where = ("configuration %q"):format(config.name)
  local cmd = config.cmd
  if type(cmd) ~= "string" and type(cmd) ~= "table" then
    return false, where .. " needs a cmd (a string or a list of strings)"
  end
  if type(cmd) == "table" then
    if #cmd == 0 then
      return false, where .. " has an empty cmd"
    end
    for _, part in ipairs(cmd) do
      if type(part) ~= "string" then
        return false, where .. " has a non-string in cmd"
      end
    end
  end
  if config.args ~= nil then
    if type(config.args) ~= "table" then
      return false, where .. " args should be a list"
    end
    for _, a in ipairs(config.args) do
      if type(a) ~= "string" then
        return false, where .. " has a non-string in args"
      end
    end
  end
  if config.env ~= nil then
    if type(config.env) ~= "table" then
      return false, where .. " env should be an object"
    end
    for k, v in pairs(config.env) do
      if type(k) ~= "string" or type(v) ~= "string" then
        return false, where .. " env should map strings to strings"
      end
    end
  end
  if config.cwd ~= nil and type(config.cwd) ~= "string" then
    return false, where .. " cwd should be a string"
  end
  -- desc goes straight to overseer, which rejects the template definition for
  -- a non-string and drops it from the picker with only a log line -- so the
  -- configuration would be runnable by name and invisible in <leader>oo. JSON
  -- null decodes to vim.NIL, which is truthy, so `~= nil` is not enough.
  if config.desc ~= nil and type(config.desc) ~= "string" then
    return false, where .. " desc should be a string"
  end
  return true
end

---Read the configurations for a project.
---@param root? string
---@return table[] configs, string|nil err
function M.load(root)
  local path = M.file(root)
  if not vim.uv.fs_stat(path) then
    return {}, nil
  end

  local ok, text = pcall(function()
    return table.concat(vim.fn.readfile(path), "\n")
  end)
  if not ok then
    return {}, "Could not read " .. path
  end
  if vim.trim(text) == "" then
    return {}, nil
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return {}, ("%s is not valid JSON: %s"):format(M.FILE, tostring(decoded))
  end
  if type(decoded) ~= "table" then
    return {}, M.FILE .. " should contain an object"
  end

  -- Accept a bare list too; it is the obvious thing to write by hand.
  local list = decoded.configurations
  if list == nil and vim.islist(decoded) then
    list = decoded
  end
  if list == nil then
    return {}, M.FILE .. ' should have a "configurations" list'
  end
  if not require("kebab.jsonfile").is_array(list) then
    return {}, M.FILE .. ' "configurations" should be a list'
  end

  local out = {}
  for i, config in ipairs(list) do
    local valid, err = M.validate(config, i)
    if not valid then
      return {}, ("%s: %s"):format(M.FILE, err)
    end
    out[#out + 1] = config
  end
  return out, nil
end

---Write configurations back, pretty-printed so the file stays hand-editable.
---@param root string
---@param configs table[]
---@return boolean ok, string|nil err
function M.save(root, configs)
  for i, config in ipairs(configs) do
    local ok, err = M.validate(config, i)
    if not ok then
      return false, err
    end
  end
  local path = M.file(root)
  local encoded = vim.json.encode({ configurations = configs })
  local wrote, werr = require("kebab.fs").write_lines(path, require("kebab.jsonfile").pretty(encoded))
  if not wrote then
    return false, werr
  end
  return true
end

---Turn a configuration into an overseer template definition.
---@param config table
---@param root string
function M.to_template(config, root)
  local cmd = type(config.cmd) == "string" and { config.cmd } or vim.deepcopy(config.cmd)
  return {
    name = config.name,
    desc = config.desc or (M.FILE .. " · " .. table.concat(cmd, " ")),
    builder = function()
      local cwd = config.cwd
      if cwd == nil or cwd == "" or cwd == "." then
        cwd = root
      elseif not cwd:match("^/") then
        cwd = root .. "/" .. cwd
      end
      return {
        cmd = cmd,
        args = vim.deepcopy(config.args or {}),
        cwd = cwd,
        env = config.env and vim.deepcopy(config.env) or nil,
        components = { "default" },
      }
    end,
  }
end

---The overseer template provider. Re-read on every search, so editing
---.kebab/run.json takes effect without a restart and switching project picks
---up the new file.
function M.provider()
  return {
    name = "kebab project run configurations",
    generator = function(opts, cb)
      local root = M.root_of(opts and opts.dir or vim.fn.getcwd())
      local configs, err = M.load(root)
      if err then
        -- Surfaced once, not on every keystroke of the task picker.
        vim.notify_once(err, vim.log.levels.WARN)
        return cb({})
      end
      local out = {}
      for _, config in ipairs(configs) do
        out[#out + 1] = M.to_template(config, root)
      end
      cb(out)
    end,
  }
end

---Open .kebab/run.json, creating a commented example if it is not there.
function M.edit()
  local root = M.root_of()
  local path = M.file(root)
  if not vim.uv.fs_stat(path) then
    local kind = registry.kind_of(root)
    local example = M.example_for(kind)
    local ok, err = M.save(root, { example })
    if not ok then
      return vim.notify(err, vim.log.levels.ERROR)
    end
    vim.notify("Created " .. M.FILE .. " with an example configuration")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

---A starting configuration that suits the project in hand, so the file opens
---with something runnable rather than an empty skeleton.
---@param kind string|nil
function M.example_for(kind)
  local examples = {
    maven = { name = "run (local profile)", cmd = { "./mvnw" },
      args = { "spring-boot:run", "-Dspring-boot.run.profiles=local" },
      env = { LOG_LEVEL = "debug" } },
    gradle = { name = "run", cmd = { "./gradlew" }, args = { "bootRun" } },
    go = { name = "run", cmd = { "go" }, args = { "run", "." }, env = { LOG_LEVEL = "debug" } },
    rust = { name = "run", cmd = { "cargo" }, args = { "run" }, env = { RUST_LOG = "debug" } },
    node = { name = "dev", cmd = { "npm" }, args = { "run", "dev" } },
    python = { name = "run", cmd = { "python3" }, args = { "-m", "src.main" } },
    flutter = { name = "run (debug)", cmd = { "flutter" }, args = { "run", "--debug" } },
  }
  return examples[kind or ""] or { name = "run", cmd = { "echo" }, args = { "configure me" } }
end

---Add a configuration interactively and append it to the file.
function M.add()
  local root = M.root_of()
  local configs, err = M.load(root)
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  vim.ui.input({ prompt = "Configuration name: " }, function(name)
    if not name or vim.trim(name) == "" then
      return
    end
    local example = M.example_for(registry.kind_of(root))
    vim.ui.input({
      prompt = "Command: ",
      default = table.concat(example.cmd, " ") .. " " .. table.concat(example.args or {}, " "),
    }, function(line)
      if not line or vim.trim(line) == "" then
        return
      end
      local parts = vim.split(vim.trim(line), "%s+")
      local config = { name = vim.trim(name), cmd = { parts[1] }, args = vim.list_slice(parts, 2) }
      configs[#configs + 1] = config
      local ok, serr = M.save(root, configs)
      if not ok then
        return vim.notify(serr, vim.log.levels.ERROR)
      end
      vim.notify(("Added %q to %s"):format(config.name, M.FILE))
    end)
  end)
end

---Run a project configuration, by name or by picking one.
---@param name? string
function M.run(name)
  local root = M.root_of()
  local configs, err = M.load(root)
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  if #configs == 0 then
    return vim.notify(
      ("No run configurations in %s (:IdeRunConfigEdit creates one)"):format(M.FILE),
      vim.log.levels.INFO)
  end

  local function start(config)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
      return vim.notify("overseer is not available", vim.log.levels.WARN)
    end
    local template = M.to_template(config, root)
    local task = overseer.new_task(template.builder())
    task:start()
    overseer.open({ enter = false })
  end

  if name and name ~= "" then
    for _, config in ipairs(configs) do
      if config.name == name then
        return start(config)
      end
    end
    for _, config in ipairs(configs) do
      if config.name:lower():find(name:lower(), 1, true) then
        return start(config)
      end
    end
    return vim.notify(("No configuration matching %q"):format(name), vim.log.levels.WARN)
  end

  vim.ui.select(configs, {
    prompt = "Run configuration",
    format_item = function(c)
      local cmd = type(c.cmd) == "string" and c.cmd or table.concat(c.cmd, " ")
      return ("%-28s %s %s"):format(c.name, cmd, table.concat(c.args or {}, " "))
    end,
  }, function(choice)
    if choice then
      start(choice)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("IdeRunConfig", function(cmd)
    M.run(cmd.args ~= "" and cmd.args or nil)
  end, { nargs = "?", desc = "Run a project run configuration" })

  vim.api.nvim_create_user_command("IdeRunConfigEdit", function()
    M.edit()
  end, { desc = "Edit this project's run configurations" })

  vim.api.nvim_create_user_command("IdeRunConfigNew", function()
    M.add()
  end, { desc = "Add a project run configuration" })
end

return M
