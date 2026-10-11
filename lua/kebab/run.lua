-- Gating a task on the project's marker files.
--
-- Split out of plugins/run.lua so it can be tested without overseer: the bug
-- it exists for was invisible to anything that only checked that templates
-- were registered.
--
-- overseer's `condition` understands `filetype`, `dir` and `tags` -- and
-- nothing else. A `condition = { callback = fn }` is accepted and then
-- ignored, so every marker-gated task was offered in every project. A provider
-- is the supported way to decide at search time, and it is also the only way
-- to test the directory being searched rather than Neovim's cwd.
local M = {}

---The marker files that make a task relevant, as a list.
---@param task table
---@return string[]|nil
function M.markers_of(task)
  local markers = task.marker
  if markers == nil then
    return nil
  end
  return type(markers) == "string" and { markers } or markers
end

---Is `task` relevant to the project at `dir`?
---@param task table
---@param dir string
function M.applies(task, dir)
  local markers = M.markers_of(task)
  if markers == nil then
    return true
  end
  for _, marker in ipairs(markers) do
    if vim.uv.fs_stat(("%s/%s"):format(dir, marker)) then
      return true
    end
  end
  return false
end

---The tasks relevant to `dir`, in declaration order.
---@param tasks table[]
---@param dir string
function M.relevant(tasks, dir)
  local out = {}
  for _, task in ipairs(tasks or {}) do
    if M.applies(task, dir) then
      out[#out + 1] = task
    end
  end
  return out
end

---An overseer provider that offers only the tasks whose marker is present.
---@param tasks table[]
---@param to_template? fun(task: table): table
function M.marker_provider(tasks, to_template)
  to_template = to_template
    or function(task)
      return {
        name = task.name,
        desc = task.desc,
        builder = function()
          local cmd = type(task.cmd) == "function" and task.cmd() or vim.deepcopy(task.cmd)
          local args = vim.tbl_map(function(a)
            return a == "%:p" and vim.fn.expand("%:p") or a
          end, task.args or {})
          return { cmd = cmd, args = args, components = { "default" } }
        end,
      }
    end
  return {
    name = "kebab language tasks",
    generator = function(opts, cb)
      local dir = (opts and opts.dir) or vim.fn.getcwd()
      local out = {}
      for _, task in ipairs(M.relevant(tasks, dir)) do
        out[#out + 1] = to_template(task)
      end
      cb(out)
    end,
  }
end

return M
