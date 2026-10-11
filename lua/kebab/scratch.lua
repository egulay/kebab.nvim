-- Scratch files -- BACKLOG.md item 4.
--
-- A graphical IDE's scratch files are real files kept outside the project, so a
-- language server attaches and they survive a restart. That is what this does:
-- `:IdeScratch http` opens a numbered .http file under stdpath("data"), with
-- kulala, vtsls or whatever else serving it as normal.
--
-- A `:enew` buffer would be simpler and much less useful: no filetype, no LSP,
-- gone when you quit.
local M = {}

local registry = require("kebab.registry")

---Where scratch files live. Under stdpath("data") rather than in the project,
---so they are never committed by accident.
function M.dir()
  return (vim.g.kebab_scratch_dir and require("kebab.path").expand(vim.g.kebab_scratch_dir))
    or (vim.fn.stdpath("data") .. "/kebab/scratch")
end

---Every scratch kind any language declares, plus the always-available ones.
---@return table[]
function M.kinds()
  return registry.collect("scratch")
end

---@param key string
---@return table|nil
function M.kind(key)
  for _, k in ipairs(M.kinds()) do
    if k.key == key then
      return k
    end
  end
  return nil
end

---The next free path for `kind`, so opening two scratches does not reuse one.
---@param kind table
---@return string
function M.next_path(kind)
  local dir = M.dir()
  vim.fn.mkdir(dir, "p")
  local ext = kind.extension
  -- A language may need a stem that is a valid identifier in it.
  local stem = kind.stem or "scratch-%d"
  for i = 1, 1000 do
    local path = ("%s/%s.%s"):format(dir, stem:format(i), ext)
    if not vim.uv.fs_stat(path) then
      return path
    end
  end
  -- 1000 scratches of one kind is not a real case, but silently overwriting
  -- the last one would be.
  return ("%s/%s.%s"):format(dir, stem:format(vim.uv.hrtime()), ext)
end

---Open a new scratch file of `kind`.
---@param kind table|string
---@param opts? { open?: boolean }
---@return boolean ok, string path_or_err
function M.open(kind, opts)
  opts = opts or {}
  if type(kind) == "string" then
    local found = M.kind(kind)
    if not found then
      local keys = vim.tbl_map(function(k) return k.key end, M.kinds())
      return false, ("Unknown scratch kind %q (have: %s)"):format(kind, table.concat(keys, ", "))
    end
    kind = found
  end
  if type(kind) ~= "table" or not kind.extension then
    return false, "A scratch kind needs an extension"
  end

  local path = M.next_path(kind)
  local lines = {}
  if type(kind.render) == "function" then
    lines = kind.render({ path = path, name = vim.fn.fnamemodify(path, ":t:r") }) or {}
  elseif type(kind.lines) == "table" then
    lines = kind.lines
  end

  local wrote, werr = require("kebab.fs").write_lines(path, lines)
  if not wrote then
    return false, werr
  end

  if opts.open ~= false then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if kind.filetype then
      vim.bo.filetype = kind.filetype
    end
  end
  return true, path
end

---Existing scratch files, newest first.
---@return table[] { path, name, kind }
function M.list()
  local dir = M.dir()
  local out = {}
  local fd = vim.uv.fs_scandir(dir)
  if not fd then
    return out
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if typ ~= "directory" then
      local path = dir .. "/" .. name
      local stat = vim.uv.fs_stat(path)
      out[#out + 1] = {
        path = path,
        name = name,
        mtime = stat and stat.mtime and stat.mtime.sec or 0,
      }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

---Pick a scratch kind to create.
function M.pick_new()
  local kinds = M.kinds()
  if #kinds == 0 then
    return vim.notify("No scratch kinds are registered", vim.log.levels.WARN)
  end
  vim.ui.select(kinds, {
    prompt = "New scratch file",
    format_item = function(k) return ("%-22s .%s"):format(k.name, k.extension) end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, result = M.open(choice)
    if not ok then
      vim.notify(result, vim.log.levels.ERROR)
    end
  end)
end

---Pick an existing scratch file to reopen.
function M.pick_existing()
  local files = M.list()
  if #files == 0 then
    return vim.notify("No scratch files yet (:IdeScratch creates one)", vim.log.levels.INFO)
  end
  vim.ui.select(files, {
    prompt = "Open scratch file",
    format_item = function(f) return f.name end,
  }, function(choice)
    if choice then
      vim.cmd("edit " .. vim.fn.fnameescape(choice.path))
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("IdeScratch", function(cmd)
    if cmd.args == "" then
      return M.pick_new()
    end
    local ok, result = M.open(cmd.args)
    if not ok then
      vim.notify(result, vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    desc = "New scratch file (:IdeScratch http, sql, …)",
    complete = function(lead)
      local out = {}
      for _, k in ipairs(M.kinds()) do
        if k.key:find(lead, 1, true) == 1 then
          out[#out + 1] = k.key
        end
      end
      return out
    end,
  })

  vim.api.nvim_create_user_command("IdeScratchList", function()
    M.pick_existing()
  end, { desc = "Open an existing scratch file" })
end

return M
