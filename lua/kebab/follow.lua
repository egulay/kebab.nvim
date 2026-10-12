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
  stop_fns = {},     -- one per watched root
  roots = {},
  seq_at = {},       -- path -> when it arrived, so a held change can go stale
  retry = nil,       -- re-check timer while the user is busy
  held_reason = nil, -- why the view is not moving right now
  root = nil,        -- the first one, for the statusline
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
    -- How long a change is held while you are busy (typing, unsaved changes,
    -- a picker open) before it is treated as stale. Held rather than dropped:
    -- dropping is why an agent's whole burst could go unseen.
    hold_ms = 30000,
    -- how often to re-check whether you are free again
    retry_ms = 400,
    -- Open a file that is not already in a buffer.
    --
    -- On, because an agent creating files is the normal case and not following
    -- them is what makes this look broken. It does not mean 40 buffers for 40
    -- files: a burst is coalesced and only the chosen file of each flush is
    -- opened, so it is one buffer per burst.
    open_new = true,
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
  -- A watcher event can still arrive after stop(): the stop is an asynchronous
  -- SIGINT, and whatever inotifywait had already written is still delivered.
  -- Without this the view moved after the user turned following off.
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
  local seq = STATE.pending
  local paths = {}
  for path in pairs(seq) do
    paths[#paths + 1] = path
  end
  if #paths == 0 then
    return
  end
  table.sort(paths, function(a, b)
    if seq[a] ~= seq[b] then
      return seq[a] < seq[b]
    end
    return a < b
  end)

  -- The badge reports activity straight away, whether or not the view is about
  -- to move. The agent *is* working, and saying so is the indicator's whole
  -- job -- it used to only appear if the jump happened, so a user mid-edit saw
  -- nothing at all while a burst of edits went by.
  local newest = paths[#paths]
  pcall(function()
    require("kebab.ghostbar").activity(newest)
  end)

  local reason = M.yielding()
  if reason then
    -- HELD, not discarded. Discarding is why an agent's whole burst could
    -- vanish: with unsaved changes in the current buffer every flush threw its
    -- pending set away, so nothing was ever shown -- and then the next change
    -- after you went idle looked like the only thing that happened.
    --
    -- Anything older than hold_ms is genuinely stale and dropped, so this
    -- cannot grow without bound or jump to something from minutes ago.
    local cutoff = vim.uv.now() - (cfg.hold_ms or 30000)
    local kept, n = {}, 0
    for path, when in pairs(seq) do
      if (STATE.seq_at[path] or 0) >= cutoff then
        kept[path] = when
        n = n + 1
      end
    end
    STATE.pending = kept
    STATE.held_reason = reason
    if n > 0 then
      -- Retry until the user is free. Not the debounce timer: that one is
      -- armed by new events, and a held burst may get none.
      M.arm_retry(cfg)
    end
    return
  end

  STATE.pending = {}
  STATE.held_reason = nil
  local chosen = cfg.follow == "first" and paths[1] or paths[#paths]
  pcall(M.follow_file, chosen, { cfg = cfg })
end

---Re-check later whether the user is still busy, so a held burst is not lost.
---@param cfg table
function M.arm_retry(cfg)
  if STATE.retry then
    return false
  end
  STATE.retry = vim.uv.new_timer()
  STATE.retry:start(
    cfg.retry_ms or 400,
    cfg.retry_ms or 400,
    vim.schedule_wrap(function()
      if not STATE.running or next(STATE.pending) == nil then
        return M.cancel_retry()
      end
      if M.yielding() then
        return
      end
      M.cancel_retry()
      flush()
    end)
  )
  return true
end

---Stop the retry timer, if one is armed.
function M.cancel_retry()
  if not STATE.retry then
    return false
  end
  pcall(function()
    STATE.retry:stop()
    if not STATE.retry:is_closing() then
      STATE.retry:close()
    end
  end)
  STATE.retry = nil
  return true
end

---Record a change, to be acted on after the debounce window.
---@param path string
-- Paths this editor has just written, and when. The watcher cannot tell who
-- wrote a file, so without this a manual :w fires Ghost Mode exactly like an
-- agent's write: the badge lights, and the view can jump to the file you are
-- already in. Reported as "I manually edit a file. I edit not an LLM... and
-- still shows me ghost mode".
local OWN = {}

---How long after our own write a change to that path is still ours.
---
---Generous enough to cover the watcher's latency and the debounce, short
---enough that a genuine external write moments after your save is not missed.
function M.own_write_ms()
  local cfg = M.config()
  local n = tonumber(cfg.own_write_ms)
  if n and n >= 0 then
    return n
  end
  return 1500
end

---Remember that we wrote this path.
---@param path string
function M.note_own_write(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  OWN[vim.fs.normalize(path)] = vim.uv.now()
  return true
end

---Was this change ours?
---
---Time-limited, and *not* consumed on the first match. One `:w` produces
---several inotify events -- a write, an attribute change, and for a plugin
---that writes through a temp file a create and a rename as well -- so
---consuming the record made the first event ours and every one after it
---somebody else's. That is exactly the bug this was meant to fix, and it made
---the spec flaky rather than failing: whichever event arrived first decided
---the answer.
---
---The cost is a window of `own_write_ms` in which an external write to a file
---*you* just saved is attributed to you. 1.5 seconds, against several events
---per save as the normal case: the right way round.
---@param path string
function M.is_own_write(path)
  local key = vim.fs.normalize(path)
  local at = OWN[key]
  if not at then
    return false
  end
  if (vim.uv.now() - at) <= M.own_write_ms() then
    return true
  end
  OWN[key] = nil -- stale: stop holding it against future changes
  return false
end

---Forget every noted write. Called by stop(), so a new session starts clean.
function M.forget_own_writes()
  OWN = {}
end

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
  -- Our own save is not an external change. The whole feature is "something
  -- else touched this project", and a badge that lights when *you* press :w
  -- says nothing.
  if M.is_own_write(path) then
    return false
  end
  STATE.seq = (STATE.seq or 0) + 1
  STATE.pending[path] = STATE.seq
  STATE.seq_at[path] = vim.uv.now()
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

---Every directory following should watch.
---
---The project root, plus anything in `vim.g.kebab_follow_roots`. That list is
---what makes an agent working in a *different* project visible: a watcher only
---ever sees its own tree, so following the project you have open cannot show
---you edits somewhere else -- which is the one thing this feature exists for.
---
---Deliberately not "all of ~/Projects" by default: `vim._watch.inotify` shells
---out to `inotifywait -r`, which places a watch on every subdirectory, so a
---large tree can exhaust `fs.inotify.max_user_watches`. Name the projects you
---want.
---@param root? string an explicit root, used alone when given
---@return string[]
function M.roots(root)
  if type(root) == "table" then
    return root
  end
  if type(root) == "string" and root ~= "" then
    return { root }
  end
  local out = {}
  local function add(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    local full = require("kebab.path").expand(dir)
    if vim.fn.isdirectory(full) == 1 and not vim.tbl_contains(out, full) then
      out[#out + 1] = full
    end
  end
  add((LazyVim and LazyVim.root and LazyVim.root()) or vim.uv.cwd())
  local extra = vim.g.kebab_follow_roots
  if type(extra) == "string" then
    add(extra)
  elseif type(extra) == "table" then
    for _, dir in ipairs(extra) do
      add(dir)
    end
  end
  return out
end

---Start watching. `root` may be a directory, a list of them, or nil for
---M.roots().
---@param root? string|string[]
---@return boolean ok, string|nil err
function M.start(root)
  if STATE.running then
    return false, "already following"
  end
  -- Never abandon watchers from a previous start. A scheduled autostart can
  -- land after the caller already stopped -- it sets running = false, so this
  -- is reachable -- and the old inotifywait would then run until the process
  -- died. Seven of them survived one suite run that way.
  for _, stop in ipairs(STATE.stop_fns or {}) do
    pcall(stop)
  end
  STATE.stop_fns = {}
  local roots = M.roots(root)
  if #roots == 0 then
    return false, "nothing to watch"
  end

  local ok, watch = pcall(require, "vim._watch")
  if not ok then
    return false, "vim._watch is not available in this Neovim"
  end
  local backend = watch.inotify or watch.watchdirs or watch.watch
  if not backend then
    return false, "no file-watching backend available"
  end

  local stops, failed = {}, {}
  for _, dir in ipairs(roots) do
    local started, stop_or_err = pcall(backend, dir, {}, function(path, _change)
      -- The callback runs off the main loop; everything that touches buffers is
      -- scheduled by on_change's timer.
      M.on_change(path)
    end)
    if started then
      if type(stop_or_err) == "function" then
        stops[#stops + 1] = stop_or_err
      end
    else
      failed[#failed + 1] = ("%s (%s)"):format(dir, tostring(stop_or_err))
    end
  end

  if #stops == 0 then
    return false, "could not start the watcher: " .. table.concat(failed, ", ")
  end

  STATE.running = true
  STATE.stop_fns = stops
  STATE.roots = roots
  STATE.root = roots[1]
  STATE.count = 0
  -- The badge is NOT shown here. It is an activity light: it appears when
  -- something actually touches the project (see ghostbar.activity, called from
  -- flush) and hides again when things go quiet. Showing it merely because
  -- watching is armed told you nothing about whether an agent was doing
  -- anything, which is the only question it answers.
  if #failed > 0 then
    -- Partial is still useful; say which root is not covered.
    vim.notify(("Follow: could not watch %s"):format(table.concat(failed, ", ")), vim.log.levels.WARN)
  end
  return true
end

function M.stop()
  M.forget_own_writes()
  if not STATE.running then
    -- Still tidy up: a timer armed by an event that arrived during the last
    -- stop would otherwise stay open for the session.
    M.cancel_timer()
    M.cancel_retry()
    STATE.pending = {}
    return false, "not following"
  end
  -- A stop the user asked for must stick: autostart fires on BufEnter, so
  -- without this the next buffer switch started it again and <leader>uf could
  -- not turn it off at all. Cleared when the project changes.
  STATE.suppress_autostart = true
  for _, stop in ipairs(STATE.stop_fns or {}) do
    pcall(stop)
  end
  M.cancel_timer()
  M.cancel_retry()
  STATE.running = false
  STATE.stop_fns = {}
  STATE.roots = {}
  STATE.pending = {}
  STATE.seq_at = {}
  STATE.held_reason = nil
  pcall(function()
    require("kebab.ghostbar").hide()
  end)
  return true
end

---Let autostart start again: forget both the "already started for this tree"
---marker and a stop the user asked for.
---
---Called when the project changes, and by the specs, which need the same
---fresh-decision semantics within one session.
function M.allow_autostart()
  STATE.autostarted_for = nil
  STATE.suppress_autostart = false
  return true
end

function M.running()
  return STATE.running
end

---How many of our own writes are currently remembered. Diagnostic: a spec
---asserting "our save was ignored" cannot tell "it was recognised as ours"
---from "the autocmd never ran", and those have different fixes.
function M.own_write_count()
  local n = 0
  for _ in pairs(OWN) do
    n = n + 1
  end
  return n
end

function M.state()
  return {
    running = STATE.running,
    root = STATE.root,
    roots = vim.deepcopy(STATE.roots or {}),
    last = STATE.last,
    count = STATE.count,
    pending = vim.tbl_count(STATE.pending),
    held_reason = STATE.held_reason,
    own_writes = M.own_write_count(),
  }
end

---For a statusline: "" when off.
function M.status()
  if not STATE.running then
    return ""
  end
  local extra = #(STATE.roots or {}) > 1 and ("/%d"):format(#STATE.roots) or ""
  return ("󰊠 following%s%s"):format(extra, STATE.count > 0 and (" " .. STATE.count) or "")
end

function M.toggle()
  if STATE.running then
    local ok = M.stop()
    if ok then
      vim.notify("Follow: off")
    end
    return ok
  end
  STATE.suppress_autostart = false
  local ok, err = M.start()
  if not ok then
    vim.notify("Follow: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  local roots = STATE.roots or { STATE.root }
  local shown = {}
  for _, dir in ipairs(roots) do
    shown[#shown + 1] = vim.fn.fnamemodify(dir, ":~")
  end
  vim.notify(("Follow: on — watching %s"):format(table.concat(shown, ", ")))
  return true
end

function M.setup()
  vim.api.nvim_create_user_command("IdeFollow", function()
    M.toggle()
  end, { desc = "Follow file changes made outside the editor (ghost programming)" })

  vim.api.nvim_create_user_command("IdeFollowStatus", function()
    local s = M.state()
    if not s.running then
      -- Say how to turn it on. "Follow: off" on its own was the whole
      -- diagnosis a user got when they expected it to be working.
      return vim.notify(
        "Follow: off\n<leader>uf or :IdeFollow turns it on"
          .. "\nvim.g.kebab_follow_autostart = true starts it for every project"
      )
    end
    vim.notify(("Follow: on\nwatching: %s\nfollowed: %d"):format(
      table.concat(s.roots and #s.roots > 0 and s.roots or { tostring(s.root) }, "\n          "),
      s.count
    ))
  end, { desc = "Report what the follower is doing" })

  local group = vim.api.nvim_create_augroup("kebab_follow", { clear = true })

  -- Our own writes, noted before the watcher reports them. BufWritePost is
  -- the whole buffer; FileWritePost is a partial write (`:'<,'>w file`), and a
  -- formatter saving on top of your save goes through the same events.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileWritePost", "FileAppendPost" }, {
    group = group,
    callback = function(ev)
      local path = ev.file
      if path == nil or path == "" then
        path = vim.fn.expand("<afile>:p")
      end
      if path ~= "" then
        M.note_own_write(vim.fn.fnamemodify(path, ":p"))
      end
    end,
  })

  -- Stopping on exit matters: an inotify watch with a dead callback is a leak.
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave", "QuitPre" }, {
    group = group,
    callback = function()
      -- Set first: a scheduled autostart must not start a watcher on the way
      -- out, because nothing will stop it.
      STATE.shutting_down = true
      pcall(M.stop)
    end,
  })

  -- Auto-start, unless `vim.g.kebab_follow_autostart = false`.
  --
  -- On by default because this is the feature's whole point: having to press
  -- <leader>uf in every session is how you end up believing it does not work
  -- at all. It stays out of your way rather than asking permission -- see
  -- M.yielding, which refuses to move the view while you are typing, have
  -- unsaved changes, or have a picker open -- and <leader>uf turns it off for
  -- the session.
  --
  -- The flag is read inside the callback, never here. setup() is called from
  -- another spec's `init`, and lazy does not order `init` functions, so
  -- deciding at setup time meant the autocmd was never registered whenever
  -- that init happened to run before the one setting the flag.
  local function autostart()
    if vim.g.kebab_follow_autostart == false or M.running() or STATE.suppress_autostart then
      return
    end
    -- Never while the editor is going away. autostart is scheduled, so for a
    -- short-lived session -- `nvim -c qa`, or the editor `git commit` opens --
    -- it can land at or after VimLeavePre, and the watcher it starts then is
    -- never stopped: one orphaned inotifywait per invocation. Measured: one
    -- leak from a single `nvim -n --headless -c qa`.
    if STATE.shutting_down or vim.v.exiting ~= vim.NIL then
      return
    end
    -- Nor for a buffer that is not a project file. `git commit` and
    -- `git rebase -i` open an editor in the repository, and following their
    -- buffer is both pointless and a watcher nobody asked for. Same list
    -- explorer.lua uses.
    local ft = vim.bo[vim.api.nvim_get_current_buf()].filetype
    if ft == "gitcommit" or ft == "gitrebase" or ft == "help" or ft == "man" then
      return
    end
    -- Once per tree. BufEnter fires constantly, and `M.running()` alone was
    -- not enough: any stop in between let it start another watcher, which is
    -- how one session ended up with eight inotifywait processes on one
    -- directory.
    local roots = M.roots()
    local key = table.concat(roots, "\n")
    if key == "" or STATE.autostarted_for == key then
      return
    end
    STATE.autostarted_for = key
    local ok, err = M.start()
    if not ok and err ~= "already following" and err ~= "nothing to watch" then
      vim.notify_once(("Follow: could not start automatically (%s)"):format(tostring(err)), vim.log.levels.WARN)
    end
  end

  -- VimEnter for the session's own project, BufEnter because VimEnter has not
  -- fired while `-c` commands run and under --headless may never fire at all
  -- (the same trap explorer.lua hit), and DirChanged for `kebab open` /
  -- :IdeOpenProject, which change the working directory.
  vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, {
    group = group,
    nested = true,
    callback = function(ev)
      -- A new project means a new tree: restart rather than extend.
      if ev.event == "DirChanged" then
        if M.running() then
          pcall(M.stop)
        end
        -- A different project is a fresh decision.
        M.allow_autostart()
      end
      vim.schedule(autostart)
    end,
  })
  -- And if the editor is already up by the time setup runs, nothing above will
  -- fire on its own.
  if vim.v.vim_did_enter == 1 then
    vim.schedule(autostart)
  end
end

return M
