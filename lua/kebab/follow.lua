-- Follow an AI agent's edits live: when a file changes on disk, move the view
-- to the file and the line that changed, so you watch the work happen instead
-- of reading a diff afterwards.
--
-- No agent registration and nothing to configure per agent. The signal is just
-- "the file changed on disk while the buffer had no unsaved changes of its
-- own", which is what any external editor looks like. That also means a save
-- from another Neovim, a `git checkout` and a formatter all count -- which on
-- reflection is the feature, not a flaw.
--
-- Off by default. A view that jumps on its own is hostile while you are reading
-- something else, so this is opt-in and yields to you in several ways; see
-- M.yielding().
local M = {}

local STATE = {
  running = false,
  stop_fn = nil,
  root = nil,
  pending = {},      -- path -> change type, coalesced
  timer = nil,
  last = nil,        -- the last path followed, for the statusline
  count = 0,
}

-- ------------------------------------------------------------------ config

---Directories whose churn would drown the signal. A Maven build rewrites
---thousands of files under target/; following that is useless and expensive.
local IGNORED_DIRS = {
  ".git", "node_modules", "target", "build", "dist", ".venv", "venv",
  "__pycache__", ".gradle", ".idea", ".dart_tool", ".next", ".svelte-kit",
  ".ruff_cache", ".mypy_cache", ".pytest_cache", "vendor", ".terraform",
  ".kebab",
}

local IGNORED_SUFFIXES = {
  "~", ".swp", ".swo", ".swx", ".tmp", ".part", ".lock", ".log",
  ".class", ".o", ".so", ".pyc", ".jar",
}

function M.config()
  local defaults = {
    ignored_dirs = IGNORED_DIRS,
    ignored_suffixes = IGNORED_SUFFIXES,
    -- Coalescing window. An agent rewriting 40 files emits a burst; jumping
    -- per event would be unwatchable, so events are collected and the latest
    -- one wins.
    debounce_ms = 250,
    -- "latest" follows the most recent change; "first" stays on the first file
    -- of a burst, which is calmer when a refactor touches many files.
    follow = "latest",
    -- Open a file that is not already in a buffer. Off by default: an agent
    -- writing 40 new files should not open 40 buffers.
    open_new = false,
    highlight_ms = 1200,
  }
  local user = vim.g.kebab_follow
  if type(user) ~= "table" then
    return defaults
  end
  local cfg = vim.tbl_deep_extend("force", defaults, user)
  -- tbl_deep_extend REPLACES a list rather than merging it, so
  -- `ignored_dirs = { "generated" }` un-ignored node_modules, build, .venv and
  -- the rest -- and `ignored_suffixes = { ".bak" }` un-ignored .swp, so the
  -- follower started chasing Vim's own swap writes. Adding to the list is what
  -- anyone setting one of these means.
  for field, builtin in pairs({ ignored_dirs = IGNORED_DIRS, ignored_suffixes = IGNORED_SUFFIXES }) do
    if type(user[field]) == "table" then
      local merged = vim.deepcopy(builtin)
      for _, entry in ipairs(user[field]) do
        if not vim.tbl_contains(merged, entry) then
          merged[#merged + 1] = entry
        end
      end
      cfg[field] = merged
    end
  end
  -- ...and an explicit opt-out, because "ignore nothing" has to be sayable.
  if user.replace_ignores == true then
    cfg.ignored_dirs = user.ignored_dirs or {}
    cfg.ignored_suffixes = user.ignored_suffixes or {}
  end
  return cfg
end

-- ----------------------------------------------------------------- filters

---Should this path be ignored outright?
---@param path string
---@param cfg? table
function M.ignored(path, cfg)
  cfg = cfg or M.config()
  if type(path) ~= "string" or path == "" then
    return true
  end
  for _, suffix in ipairs(cfg.ignored_suffixes) do
    if path:sub(-#suffix) == suffix then
      return true
    end
  end
  -- match whole path segments, so a project called "build-tools" is not ignored
  for segment in path:gmatch("[^/]+") do
    for _, dir in ipairs(cfg.ignored_dirs) do
      if segment == dir then
        return true
      end
    end
  end
  -- 4913 and friends: the files Vim itself writes to test a directory
  if path:match("/%d%d%d%d$") then
    return true
  end
  return false
end

---Reasons not to move the view right now. Returns nil when it is fine to
---follow, or a short reason.
---
---This is the part that keeps it from being hostile: whatever an agent is
---doing, the user's own editing wins.
function M.yielding()
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("^i") or mode:match("^R") then
    return "insert mode"
  end
  if mode:match("^[vV\22]") then
    return "visual selection"
  end
  if mode:match("^c") then
    return "command line"
  end
  if vim.fn.pumvisible() == 1 then
    return "completion menu open"
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].modified then
    return "this buffer has unsaved changes"
  end
  local ft = vim.bo[buf].filetype
  -- a picker, a terminal or a prompt has the user's attention
  if vim.bo[buf].buftype == "terminal" or vim.bo[buf].buftype == "prompt" then
    return "terminal or prompt focused"
  end
  if ft == "TelescopePrompt" or ft == "snacks_picker_input" or ft == "snacks_input" then
    return "picker open"
  end
  return nil
end

-- -------------------------------------------------------------------- diff

---The first line at which two versions differ, or nil when they are the same.
---
---Used to put the cursor where the change is rather than at the top of the
---file, which is the difference between watching an edit and being told one
---happened.
---@param before string[]
---@param after string[]
---@return number|nil
function M.first_change(before, after)
  local n = math.max(#before, #after)
  for i = 1, n do
    if before[i] ~= after[i] then
      return i
    end
  end
  return nil
end

---The buffer displaying `path`, if any.
---@param path string
function M.buffer_for(path)
  local target = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.resolve(vim.fn.fnamemodify(name, ":p")) == target then
        return buf
      end
    end
  end
  return nil
end

-- ----------------------------------------------------------------- acting

local NS = vim.api.nvim_create_namespace("kebab_follow")

---Briefly highlight the line that changed.
function M.flash(buf, line, cfg)
  cfg = cfg or M.config()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, math.max(0, line - 1), 0, {
    line_hl_group = "DiffText",
    hl_eol = true,
  })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  end, cfg.highlight_ms)
end

---Reload a buffer from disk and move the cursor to the first changed line.
---Returns the line followed to, or nil plus a reason.
---@param path string
---@param opts? { cfg?: table, jump?: boolean }
function M.follow_file(path, opts)
  opts = opts or {}
  local cfg = opts.cfg or M.config()
  local buf = M.buffer_for(path)

  if not buf then
    if not cfg.open_new then
      return nil, "not open"
    end
    if not vim.uv.fs_stat(path) then
      return nil, "gone"
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    STATE.last = path
    STATE.count = STATE.count + 1
    return 1
  end

  -- Never reload over the user's own edits. A buffer that is modified *and*
  -- changed on disk is a conflict, and silently discarding either side is the
  -- one thing this must not do.
  if vim.bo[buf].modified then
    vim.notify(
      ("%s changed on disk, but this buffer has unsaved changes — not reloading")
        :format(vim.fn.fnamemodify(path, ":~:.")),
      vim.log.levels.WARN)
    return nil, "conflict"
  end

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- checktime is what actually rereads it; autoread is on by default
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! checktime")
  end)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line = M.first_change(before, after)

  STATE.last = path
  STATE.count = STATE.count + 1

  if opts.jump == false then
    return line or 1
  end

  -- Show the buffer in a window, without stealing a special window.
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    local ok = pcall(function()
      vim.api.nvim_set_current_buf(buf)
    end)
    if not ok then
      return line or 1
    end
    win = vim.api.nvim_get_current_win()
  else
    pcall(vim.api.nvim_set_current_win, win)
  end

  if line then
    local count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(line, count), 0 })
    pcall(vim.cmd, "normal! zz")
    M.flash(buf, line, cfg)
  end
  return line or 1
end

-- ---------------------------------------------------------------- watching

---Flush the coalesced events.
local function flush()
  -- A watcher event can still arrive after stop(): STATE.stop_fn sends an
  -- asynchronous SIGINT, and whatever inotifywait had already written is still
  -- delivered. Without this the view moved after the user turned following off.
  if not STATE.running then
    STATE.pending = {}
    return
  end
  local cfg = M.config()
  -- Ordered by when each change arrived, not by name. STATE.pending used to be
  -- a plain set, so insertion order was irrecoverable and `table.sort` made
  -- "latest" mean "alphabetically last" -- the two modes were effectively
  -- swapped, and a path sorting after the one being edited masked it for the
  -- whole session.
  local paths = {}
  for path in pairs(STATE.pending) do
    paths[#paths + 1] = path
  end
  local seq = STATE.pending
  STATE.pending = {}
  if #paths == 0 then
    return
  end
  table.sort(paths, function(a, b)
    if seq[a] ~= seq[b] then
      return seq[a] < seq[b]
    end
    return a < b
  end)

  local reason = M.yielding()
  if reason then
    -- Dropped rather than queued: by the time you leave insert mode the jump
    -- would be about something you have stopped caring about.
    return
  end

  local chosen = cfg.follow == "first" and paths[1] or paths[#paths]
  local ok, line = pcall(M.follow_file, chosen, { cfg = cfg })
  -- Name the file on the indicator, so the panel says what just moved rather
  -- than only that something did.
  if ok and line then
    pcall(function()
      require("kebab.ghostbar").activity(chosen)
    end)
  end
end

---Record a change, to be acted on after the debounce window.
---@param path string
function M.on_change(path)
  -- Events in flight when stop() ran must not arm a new timer: stop() early
  -- returns on `not STATE.running`, so it could never close it again and every
  -- stop-mid-burst leaked one open libuv timer for the rest of the session.
  if not STATE.running then
    return false
  end
  local cfg = M.config()
  if M.ignored(path, cfg) then
    return false
  end
  STATE.seq = (STATE.seq or 0) + 1
  STATE.pending[path] = STATE.seq
  M.cancel_timer()
  STATE.timer = vim.uv.new_timer()
  STATE.timer:start(cfg.debounce_ms, 0, function()
    vim.schedule(function()
      -- a fired one-shot timer stays open until something closes it
      M.cancel_timer()
      flush()
    end)
  end)
  return true
end

---Stop and close the debounce timer, if there is one.
function M.cancel_timer()
  if not STATE.timer then
    return false
  end
  pcall(function()
    STATE.timer:stop()
    if not STATE.timer:is_closing() then
      STATE.timer:close()
    end
  end)
  STATE.timer = nil
  return true
end

---Start watching `root`.
---
---Uses vim._watch.inotify. Note what *not* to use:
---vim.uv.new_fs_event():start(dir, { recursive = true }, cb) reports success on
---Linux and then does not recurse, so it silently watches only the top
---directory.
---@param root? string
function M.start(root)
  if STATE.running then
    return false, "already following"
  end
  root = root or ((LazyVim and LazyVim.root and LazyVim.root()) or vim.uv.cwd())

  local ok, watch = pcall(require, "vim._watch")
  if not ok then
    return false, "vim._watch is not available in this Neovim"
  end
  local backend = watch.inotify or watch.watchdirs or watch.watch
  if not backend then
    return false, "no file-watching backend available"
  end

  local started, stop_or_err = pcall(backend, root, {}, function(path, _change)
    -- The callback runs off the main loop; everything that touches buffers is
    -- scheduled by on_change's timer.
    M.on_change(path)
  end)
  if not started then
    return false, "could not start the watcher: " .. tostring(stop_or_err)
  end

  STATE.running = true
  STATE.stop_fn = type(stop_or_err) == "function" and stop_or_err or nil
  STATE.root = root
  STATE.count = 0
  -- Something else is about to move the cursor on its own, so say so without
  -- being asked. Optional on purpose: a broken indicator must not stop
  -- following from working.
  pcall(function()
    require("kebab.ghostbar").show()
  end)
  return true
end

function M.stop()
  if not STATE.running then
    -- Still tidy up: a timer armed by an event that arrived during the last
    -- stop would otherwise stay open for the session.
    M.cancel_timer()
    STATE.pending = {}
    return false, "not following"
  end
  if STATE.stop_fn then
    pcall(STATE.stop_fn)
  end
  M.cancel_timer()
  STATE.running = false
  STATE.stop_fn = nil
  STATE.pending = {}
  pcall(function()
    require("kebab.ghostbar").hide()
  end)
  return true
end

function M.running()
  return STATE.running
end

function M.state()
  return {
    running = STATE.running,
    root = STATE.root,
    last = STATE.last,
    count = STATE.count,
    pending = vim.tbl_count(STATE.pending),
  }
end

---For a statusline: "" when off.
function M.status()
  if not STATE.running then
    return ""
  end
  return ("󰊠 following%s"):format(STATE.count > 0 and (" " .. STATE.count) or "")
end

function M.toggle()
  if STATE.running then
    local ok = M.stop()
    if ok then
      vim.notify("Follow: off")
    end
    return ok
  end
  local ok, err = M.start()
  if not ok then
    vim.notify("Follow: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  vim.notify(("Follow: on — watching %s"):format(vim.fn.fnamemodify(STATE.root, ":~")))
  return true
end

function M.setup()
  vim.api.nvim_create_user_command("IdeFollow", function()
    M.toggle()
  end, { desc = "Follow file changes made outside the editor (ghost programming)" })

  vim.api.nvim_create_user_command("IdeFollowStatus", function()
    local s = M.state()
    vim.notify(("Follow: %s%s"):format(
      s.running and "on" or "off",
      s.running and ("\nroot: " .. tostring(s.root) .. "\nfollowed: " .. s.count) or ""))
  end, { desc = "Report what the follower is doing" })

  -- Stopping on exit matters: an inotify watch with a dead callback is a leak.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("kebab_follow", { clear = true }),
    callback = function()
      pcall(M.stop)
    end,
  })
end

return M
