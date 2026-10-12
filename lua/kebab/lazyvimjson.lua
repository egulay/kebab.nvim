-- Record, in LazyVim's own file, the extras this layer cannot live without.
--
-- The bug this exists for, found by installing into a container rather than
-- onto the machine it was written on:
--
--   On a *fresh* config the file tree never appears. `plugins/extras.lua`
--   imports `lazyvim.plugins.extras.editor.neo-tree`, and LazyVim silently
--   refuses that import.
--
-- Why it refuses it: LazyVim picks one explorer and one picker, and decides
-- which while its *own* spec is being built -- module 1, before this layer's
-- spec (module 6) exists. `LazyVim.config.register_defaults` asks
-- `has_extra("editor.neo-tree")`, which looks in the already-imported modules,
-- in `lazyvim.json`, and in the top-level entries of the lazy spec. A nested
-- import inside `import = "kebab.plugins"` is in none of those, so the answer
-- is no, snacks explorer wins as the default, and `LazyVim.util.plugin`'s
-- wrapper around `Spec.import` then returns false for every extra the losing
-- side owns. No warning: the explorer is simply not there, `<leader>e` opens
-- the snacks one instead, and everything in this layer built on neo-tree --
-- the always-on tree, the tree right-click menu, the pinned panes in database
-- mode -- quietly has nothing to attach to.
--
-- It worked on the author's machine because their `lazyvim.json` already
-- listed that extra, which is the one place `has_extra` can see in time. So
-- that is where it goes: the same file `:LazyExtras` writes, merged rather
-- than replaced.
local M = {}

local jsonfile = require("kebab.jsonfile")
local fs = require("kebab.fs")

---The extras this layer depends on *structurally* -- the ones whose absence
---breaks a feature rather than removing one. Only the explorer qualifies: it
---is the file tree the layer is built on, and LazyVim treats it as an
---either/or with snacks explorer.
M.REQUIRED_EXTRAS = { "lazyvim.plugins.extras.editor.neo-tree" }

---@return string
function M.path()
  return vim.fs.normalize(vim.fn.stdpath("config") .. "/lazyvim.json")
end

---Read it. Returns the decoded table (empty when there is no file) plus
---whether a file was there at all.
---@param path? string
---@return table data, boolean existed, string|nil err
function M.read(path)
  path = path or M.path()
  if vim.fn.filereadable(path) == 0 then
    return {}, false, nil
  end
  local text = table.concat(vim.fn.readfile(path), "\n")
  if vim.trim(text) == "" then
    return {}, true, nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return {}, true, ("%s is not valid JSON: %s"):format(path, tostring(decoded))
  end
  return decoded, true, nil
end

---Add `extras` to the file, keeping everything else in it.
---
---Nothing is removed: a user who has chosen other extras keeps them, and
---running this twice changes nothing. A file that does not exist yet is
---created with the same keys LazyVim writes, because leaving `install_version`
---out makes LazyVim read the file as a pre-8 install and switch the *picker*
---default as well -- a side effect nobody asked for.
---@param opts? { path?: string, extras?: string[], dry?: boolean }
---@return boolean changed, string|nil err, string[] added
function M.ensure(opts)
  opts = opts or {}
  local path = opts.path or M.path()
  local wanted = opts.extras or M.REQUIRED_EXTRAS
  local data, existed, err = M.read(path)
  if err then
    return false, err, {}
  end

  if type(data.extras) ~= "table" or not jsonfile.is_array(data.extras) then
    data.extras = {}
  end
  local added = {}
  for _, extra in ipairs(wanted) do
    if not vim.tbl_contains(data.extras, extra) then
      data.extras[#data.extras + 1] = extra
      added[#added + 1] = extra
    end
  end
  if #added == 0 then
    return false, nil, {}
  end

  if not existed then
    -- What LazyVim writes for a new install. Read from LazyVim itself when it
    -- is loaded (setup.sh runs before the plugins are installed, so usually it
    -- is not), and fall back to the current numbers.
    local version = 8
    local ok, json = pcall(function()
      return require("lazyvim.config").json
    end)
    if ok and type(json) == "table" and type(json.version) == "number" then
      version = json.version
    end
    data.news = data.news or vim.empty_dict()
    data.version = data.version or version
    data.install_version = data.install_version or version
  end

  if opts.dry then
    return true, nil, added
  end

  -- jsonfile.pretty already returns *lines*, not a string
  local lines = jsonfile.pretty(vim.json.encode(data))
  local wrote, werr = fs.write_lines(path, lines)
  if not wrote then
    return false, werr, added
  end
  return true, nil, added
end

---Is the explorer this layer needs actually in play?
---
---`kebab doctor` reports this, because the failure it guards against is
---invisible: the import is refused, nothing is logged, and the tree is just
---missing. @see M.ensure
---@return boolean ok, string detail
function M.explorer_ready()
  local ok, lazy = pcall(require, "lazy.core.config")
  if not ok then
    return false, "lazy.nvim is not loaded"
  end
  local modules = (lazy.spec or {}).modules or {}
  local extra = M.REQUIRED_EXTRAS[1]
  if vim.tbl_contains(modules, extra) then
    return true, "neo-tree"
  end
  local chosen = "snacks"
  if vim.tbl_contains(modules, "lazyvim.plugins.extras.editor.snacks_explorer") then
    chosen = "snacks explorer"
  elseif vim.g.lazyvim_explorer then
    chosen = tostring(vim.g.lazyvim_explorer)
  end
  return false,
    ("%s is in use; LazyVim refused %s. Add it to %s (or run this layer's setup.sh again)")
      :format(chosen, extra, M.path())
end

return M
