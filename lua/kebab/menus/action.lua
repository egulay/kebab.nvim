-- Menu actions that can be tested without being clicked.
--
-- The problem this solves: nvzone/menu entries are `cmd = <string|function>`.
-- A hand-written closure like
--
--     cmd = function() pcall(function() Snacks.picker.projects() end) end
--
-- is opaque -- nothing outside it can tell what it targets, and the pcall means
-- a typo or a renamed upstream function fails silently. BACKLOG.md records the
-- result: ~90 editor-menu entries verified only to *render*.
--
-- So every action is built here instead, and each builder records a descriptor
-- alongside the closure it returns. The closure is a plain function, which is
-- what the menu wants; the descriptor is what tests/spec/menu_editor_spec.lua
-- reads to check that the target still exists. Adding an opaque closure to a
-- menu now fails the sweep, by design.
local M = {}

-- fn -> descriptor. Weak keys so a discarded menu does not pin its closures.
local registry = setmetatable({}, { __mode = "k" })

-- Windows belonging to a menu that is open right now. @see M.watch
local tracked = {}

---Note every floating window a menu session opens, so it can be closed again
---even after its buffer is gone.
---
---Why it has to be the window and not the buffer: nvzone/menu closes the
---clicked menu with `volt.close(buf)`, which feeds `q` to a buffer-local
---mapping through `nvim_feedkeys(..., "x")`. From inside a mouse-click
---handler -- itself running inside a feedkeys execution -- the nested call
---does not run the mapping; what does happen is that the buffer gets wiped,
---and Neovim leaves the float open showing an empty one. So the window
---survives with no filetype to recognise it by, sitting over the screen and
---holding the focus: a picker opened from Project > New Project... came up
---unfocused, in normal mode, with typing-to-filter inert.
---
---Found by driving the wizard with a real mouse in tests/pty. None of it is
---observable without a terminal, which is why every unit test passed.
---@param which? string the menu module being opened, for the log only
function M.watch(which)
  tracked = {}
  local group = vim.api.nvim_create_augroup("KebabMenuWindows", { clear = true })
  local function note()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "NvMenu" then
          tracked[win] = which or true
        end
      end
    end
  end
  -- The filetype is set after the window is created and after volt has drawn
  -- it, so the scan is scheduled; a submenu opens later still, which is what
  -- the autocmd is for.
  vim.api.nvim_create_autocmd({ "WinNew", "BufWinEnter" }, {
    group = group,
    callback = function()
      vim.schedule(note)
    end,
  })
  vim.schedule(note)
end

---Close any right-click menu still on screen. @see M.watch
---@return integer how many windows were closed
local function close_menus()
  local closed = 0
  local function shut(win)
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      if pcall(vim.api.nvim_win_close, win, true) then
        closed = closed + 1
      end
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "NvMenu" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  for win in pairs(tracked) do
    shut(win)
  end
  tracked = {}
  -- Belt and braces: a menu this session did not see opened (another plugin's
  -- entry point, a reload) is still recognisable while its buffer lives.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "NvMenu" then
        shut(win)
      end
    end
  end
  if closed > 0 then
    local ok, state = pcall(require, "menu.state")
    if ok then
      state.bufs, state.bufids, state.nested_menu = {}, {}, ""
    end
  end
  return closed
end

---Exposed so a test can prove the cleanup happens, rather than only that a
---menu opens.
M.close_menus = close_menus

---Every menu action goes through here, so every one of them closes the menu
---first. @see close_menus
---
---When a menu really was closed the action runs one tick later. Closing the
---window fires WinClosed, and nvzone's handler schedules a cleanup that puts
---the focus back where it was before the menu opened. Running the action
---straight away means that cleanup lands *after* it, and whatever the action
---opened loses the focus: the project-type picker came up with its list
---focused in normal mode instead of its input in insert mode, so typing to
---filter did nothing. vim.schedule is FIFO, so one tick is enough -- the
---cleanup was queued first. Invoked any other way (a keymap, a test) nothing
---is closed and nothing is deferred, so the effect is still synchronous.
local function register(fn, desc)
  local wrapped = function(...)
    if close_menus() > 0 then
      -- `table.pack`/`table.unpack` do not exist in this LuaJIT; the global
      -- `unpack` does. Getting that wrong made every menu entry do nothing at
      -- all, reported by the click handler's pcall and nowhere else.
      local args, nargs = { ... }, select("#", ...)
      vim.schedule(function()
        fn(unpack(args, 1, nargs))
      end)
      return
    end
    return fn(...)
  end
  registry[wrapped] = desc
  return wrapped
end

---Describe an action built by this module. nil for anything else.
function M.describe(fn)
  return registry[fn]
end

---True for functions and for tables with a __call metamethod. Snacks exposes
---`Snacks.lazygit`, `Snacks.terminal` and friends as callable *tables*, so a
---bare type(v) == "function" check would wrongly reject half the entries.
function M.callable(v)
  if type(v) == "function" then
    return true
  end
  if type(v) == "table" then
    local mt = getmetatable(v)
    return mt ~= nil and type(mt.__call) == "function"
  end
  return false
end

---Walk a dotted path from `base`. Returns value, or nil plus the path element
---that was missing.
function M.resolve(base, path)
  local cur = base
  for part in path:gmatch("[^%.]+") do
    if type(cur) ~= "table" and not M.callable(cur) then
      return nil, part
    end
    local ok, nxt = pcall(function()
      return cur[part]
    end)
    if not ok or nxt == nil then
      return nil, part
    end
    cur = nxt
  end
  return cur, nil
end

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

---Attach a descriptor to a closure built elsewhere, so modules with their own
---calling conventions can still take part in the menu sweep. menus/tree.lua
---needs this: its actions have to refocus the tree window before running a
---neo-tree command, which none of the builders below do.
---@param fn function
---@param desc table
function M.tag(fn, desc)
  assert(type(fn) == "function", "tag needs a function")
  assert(type(desc) == "table" and desc.kind, "tag needs a descriptor with a kind")
  return register(fn, desc)
end

-- ------------------------------------------------------------------- ex

---An Ex command, optionally owned by a lazy-loaded plugin.
---
---`plugin` is a safety net: if the command is not defined yet, the plugin is
---loaded and the command retried. Menu entries should not depend on it --
---plugins/menu.lua declares `cmd` triggers so the commands are live from
---startup -- but a user who removes an extra gets a clear message instead of
---"E492: Not an editor command".
---@param cmdline string full command line, e.g. "Trouble diagnostics toggle"
---@param opts? { plugin?: string }
function M.ex(cmdline, opts)
  opts = opts or {}
  local name = cmdline:match("^%s*(%a[%w_]*)") or cmdline
  local fn = function()
    if vim.fn.exists(":" .. name) == 0 and opts.plugin then
      pcall(function()
        require("lazy").load({ plugins = { opts.plugin } })
      end)
    end
    if vim.fn.exists(":" .. name) == 0 then
      return warn((":%s is not available%s"):format(name, opts.plugin and (" (" .. opts.plugin .. " not installed?)") or ""))
    end
    local ok, err = pcall(vim.cmd, cmdline)
    if not ok then
      warn((":%s failed: %s"):format(name, tostring(err)))
    end
  end
  return register(fn, { kind = "ex", cmdline = cmdline, command = name, plugin = opts.plugin })
end

-- ------------------------------------------------------------------- module

---A function reached through `require`, e.g. M.mod("persistence", "load").
---Replaces the old local `try()` helper.
---@param module string
---@param path string dotted path within the module, e.g. "run.run"
function M.mod(module, path, ...)
  local args = { ... }
  local nargs = select("#", ...)
  local fn = function()
    local ok, m = pcall(require, module)
    if not ok then
      return warn(module .. " is not available")
    end
    local target, missing = M.resolve(m, path)
    if not target then
      return warn(("%s.%s not found (no .%s)"):format(module, path, missing))
    end
    if not M.callable(target) then
      return warn(("%s.%s is not callable"):format(module, path))
    end
    local called, err = pcall(target, unpack(args, 1, nargs))
    if not called then
      warn(("%s.%s failed: %s"):format(module, path, tostring(err)))
    end
  end
  return register(fn, { kind = "mod", module = module, path = path, args = args, nargs = nargs })
end

-- ------------------------------------------------------------------- global

---A function reached through a global set up by another plugin -- `Snacks` and
---`LazyVim` here. Both are only populated once lazy.nvim has run, so these
---cannot be resolved at menu-definition time.
---@param global string e.g. "Snacks"
---@param path string e.g. "picker.projects"
function M.g(global, path, ...)
  local args = { ... }
  local nargs = select("#", ...)
  local fn = function()
    local base = _G[global]
    if base == nil then
      return warn(global .. " is not available")
    end
    local target, missing = M.resolve(base, path)
    if not target then
      return warn(("%s.%s not found (no .%s)"):format(global, path, missing))
    end
    if not M.callable(target) then
      return warn(("%s.%s is not callable"):format(global, path))
    end
    local called, err = pcall(target, unpack(args, 1, nargs))
    if not called then
      warn(("%s.%s failed: %s"):format(global, path, tostring(err)))
    end
  end
  return register(fn, { kind = "global", global = global, path = path, args = args, nargs = nargs })
end

-- ------------------------------------------------------------------- pick

---A LazyVim picker. `LazyVim.pick(source)` does not open anything: it *returns*
---the function that does, so this needs the second call that a plain M.g would
---miss. Keeping it as its own builder means the sweep can also confirm a picker
---backend is registered, which is what actually breaks here.
---@param source string e.g. "files", "oldfiles", "live_grep"
---@param opts? table
function M.pick(source, opts)
  local fn = function()
    local base = _G.LazyVim
    if base == nil then
      return warn("LazyVim is not available")
    end
    local picker, missing = M.resolve(base, "pick")
    if not picker or not M.callable(picker) then
      return warn("LazyVim.pick not found (no ." .. tostring(missing) .. ")")
    end
    local ok, open = pcall(picker, source, opts)
    if not ok or not M.callable(open) then
      return warn(("LazyVim.pick(%q) did not return a function"):format(source))
    end
    local called, err = pcall(open)
    if not called then
      warn(("LazyVim.pick(%q) failed: %s"):format(source, tostring(err)))
    end
  end
  return register(fn, { kind = "pick", source = source, opts = opts })
end

-- ------------------------------------------------------------------- lsp

---A vim.lsp.buf.* action. Separate from M.g so the sweep can check that a
---language server is actually attached before blaming the entry.
---@param path string e.g. "definition"
function M.lsp(path, ...)
  local args = { ... }
  local nargs = select("#", ...)
  local fn = function()
    local target, missing = M.resolve(vim.lsp.buf, path)
    if not target then
      return warn("vim.lsp.buf." .. path .. " not found (no ." .. tostring(missing) .. ")")
    end
    if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
      return warn("No language server attached to this buffer")
    end
    local ok, err = pcall(target, unpack(args, 1, nargs))
    if not ok then
      warn(("vim.lsp.buf.%s failed: %s"):format(path, tostring(err)))
    end
  end
  return register(fn, { kind = "lsp", path = path, args = args, nargs = nargs })
end

-- ------------------------------------------------------------------- bespoke

---An action with logic of its own. `check` is what the sweep calls instead of
---resolving a target: it must return true, or false plus a reason. Passing a
---bare function with no check is deliberately not possible -- that is the hole
---this module exists to close.
---@param label string what the action does, for failure messages
---@param fn function
---@param check fun():boolean,string?
function M.custom(label, fn, check)
  assert(type(fn) == "function", "custom action needs a function")
  assert(type(check) == "function", "custom action '" .. label .. "' needs a check()")
  return register(fn, { kind = "custom", label = label, check = check })
end

return M
