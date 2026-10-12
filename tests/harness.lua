-- Minimal test harness.
--
-- Runs inside ONE fully-loaded Neovim, so specs see the real LazyVim/Snacks
-- globals and the real lazy.nvim plugin set -- which is the whole point: the
-- bugs this layer ships are integration bugs (a module renamed, a command that
-- never existed), not logic bugs. plenary's busted runner spawns children with
-- a minimal init and would hide exactly those.
--
-- Deliberately not placed under lua/: nothing here should be loadable by the
-- plugin at runtime.
local H = {}

local suites, current = {}, nil
local results = { pass = 0, fail = 0, skip = 0, failures = {} }

function H.describe(name, fn)
  local prev = current
  current = { name = name, parent = prev }
  suites[#suites + 1] = current
  fn()
  current = prev
end

local function full_name()
  local parts, node = {}, current
  while node do
    table.insert(parts, 1, node.name)
    node = node.parent
  end
  return table.concat(parts, " › ")
end

---Stop the file follower, whatever a test left behind.
---
---Enforced after *every* test, not only between spec files: a test that errors
---before its own `F.stop()` leaves an inotifywait process running and its
---callbacks move the next test's buffers around. Seven survived one full run
---that way -- each one a test whose assertion failed or timed out first.
function H.stop_following()
  local F = package.loaded["kebab.follow"]
  if not F then
    return false
  end
  pcall(F.stop)
  if F.allow_autostart then
    pcall(F.allow_autostart)
  end
  return true
end

function H.it(name, fn)
  local label = full_name() .. " › " .. name
  local ok, err = pcall(fn)
  pcall(H.stop_following)
  if ok then
    results.pass = results.pass + 1
    io.write("  ok   " .. label .. "\n")
  elseif type(err) == "table" and err.skip then
    results.skip = results.skip + 1
    io.write("  skip " .. label .. "  (" .. tostring(err.why) .. ")\n")
  else
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = { label = label, err = tostring(err) }
    io.write("  FAIL " .. label .. "\n       " .. tostring(err):gsub("\n", "\n       ") .. "\n")
  end
end

-- Skip rather than fail when a precondition genuinely is not available on this
-- machine (no flutter sdk, no network). A skip is honest; a fake pass is not.
function H.skip(why)
  error({ skip = true, why = why }, 0)
end

---Is this tool present *and* able to run?
---
---`executable()` answers for the file, not for the tool. GitHub's runners ship
---a `cargo` that is a rustup shim with no default toolchain: it is on PATH,
---and running it fails with "rustup could not choose a version of cargo to
---run". The spec skipped on `executable("cargo") == 0`, so it ran and failed.
---Same shape as python3 without ensurepip.
---The liveness command belongs to the tool: `go --version` is not a thing
---("flag provided but not defined: -version"), so a blanket `--version` turned
---nineteen passing tests into skips the moment this was introduced. Known
---tools carry their own; anything else gets `--version`.
---@param exe string
---@param args? string[] overrides the liveness check
---@return boolean usable, string|nil why
function H.usable(exe, args)
  if vim.fn.executable(exe) == 0 then
    return false, exe .. " is not on PATH"
  end
  local LIVENESS = { go = { "version" } }
  local cmd = { exe }
  vim.list_extend(cmd, args or LIVENESS[exe] or { "--version" })
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(30000)
  end)
  if not ok then
    return false, ("%s could not be run: %s"):format(exe, tostring(res))
  end
  if res.code ~= 0 then
    local detail = vim.trim((res.stderr or "") .. (res.stdout or "")):gsub("%s+", " ")
    return false, ("%s is on PATH but not usable: %s"):format(exe, detail:sub(1, 160))
  end
  return true, nil
end

---Run `fn` with the working directory set to `dir`, and put it back after.
---
---Why this exists rather than the obvious four lines: `cd`, `pcall(fn)`, `cd`
---back, `H.ok(ok, tostring(err))` turns a **skip into a failure**, because
---`H.skip` raises a table and the pcall catches it. CI reported two tests as
---`agent_spec.lua:469: table: 0x7f85e7518ce0` -- a failure with no message,
---on a runner that simply had no gopls. This re-raises whatever happened
---faithfully, so a skip stays a skip and an error keeps its message.
---@param dir string
---@param fn function
function H.in_dir(dir, fn)
  local saved = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local ok, err = pcall(fn)
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved))
  if not ok then
    error(err, 0)
  end
end

-- ------------------------------------------------------------- assertions

local function fmt(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return vim.inspect(v)
end

function H.eq(expected, got, msg)
  if not vim.deep_equal(expected, got) then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(got), 2)
  end
end

---`msg` may arrive as a table: a function returning `value, problems` passed
---straight into an assertion puts the second return in the message slot, and
---`tostring` on it yields "table: 0x7f85e7518ce0". Render it instead.
local function message(msg)
  if type(msg) == "table" then
    return (vim.inspect(msg):gsub("%s+", " "))
  end
  return msg
end

function H.ok(cond, msg)
  if not cond then
    error(message(msg) or "expected truthy, got " .. fmt(cond), 2)
  end
end

function H.truthy(cond, msg) return H.ok(cond, msg) end

function H.falsy(cond, msg)
  if cond then
    error((message(msg) or "expected falsy") .. ", got " .. fmt(cond), 2)
  end
end

function H.matches(pattern, s, msg)
  if type(s) ~= "string" or not s:match(pattern) then
    error((msg and (msg .. ": ") or "") .. fmt(s) .. " does not match " .. fmt(pattern), 2)
  end
end

function H.errors(fn, msg)
  local ok = pcall(fn)
  if ok then error(msg or "expected an error, call succeeded", 2) end
end

-- ------------------------------------------------------------- notify baseline

-- Everything vim.notify receives during the run, so a failing test can be
-- explained without the messages being printed over the results.
H.notify_log = {}

---Snapshot of what vim.notify received while the editor started, filled in by
---tests/run.lua once startup has settled.
H.startup_notifications = {}

---Emitted into the startup log on purpose, so a spec can tell "startup was
---silent" from "nothing was ever recorded".
H.STARTUP_SENTINEL = "kebab-test: startup notification logger is live"

-- LazyVim.lazy_notify() installs a queueing stand-in as vim.notify and only
-- swaps the original back when something *else* replaces it. That makes
-- "capture vim.notify, then restore it" actively dangerous: restoring puts the
-- stand-in back, LazyVim's replay() then pushes its queue through it, and each
-- replayed message is re-queued -- growing the queue until Lua raises
-- "table overflow" and the run dies with SIGTERM.
--
-- So the harness pins vim.notify to a baseline of its own before any spec runs.
-- The stand-in is displaced for good, replay() drains into the baseline, and a
-- spec's capture/restore cycle can only ever restore this.
function H.install_notify_baseline()
  local function baseline(msg, level, opts)
    H.notify_log[#H.notify_log + 1] = {
      msg = tostring(msg),
      level = level or vim.log.levels.INFO,
      opts = opts,
    }
  end
  vim.notify = baseline
  vim.notify_once = baseline
  -- let LazyVim's uv.check see the swap and flush its queue into the baseline
  vim.wait(500, function() return false end, 50)
  H.notify_log = {}
  return baseline
end

---The last few notifications, for failure diagnostics.
function H.recent_notifications(n)
  local out, log = {}, H.notify_log
  for i = math.max(1, #log - (n or 5) + 1), #log do
    out[#out + 1] = ("[%s] %s"):format(tostring(log[i].level), log[i].msg)
  end
  return out
end

-- ------------------------------------------------------------- capture

-- Collect vim.notify output for the duration of fn. Most of this layer reports
-- failure by notifying rather than erroring, so asserting on notifications is
-- how we tell "it worked" from "it quietly gave up".
function H.capture_notify(fn)
  local got = {}
  local orig = vim.notify
  local orig_once = vim.notify_once
  vim.notify = function(m, lvl)
    local rec = { msg = tostring(m), level = lvl or vim.log.levels.INFO }
    got[#got + 1] = rec
    H.notify_log[#H.notify_log + 1] = rec
  end
  vim.notify_once = vim.notify
  local ok, err = pcall(fn)
  vim.notify = orig
  vim.notify_once = orig_once
  if not ok then error(err, 0) end
  return got
end

function H.notified(list, pattern)
  for _, n in ipairs(list) do
    if n.msg:match(pattern) then return n end
  end
  return nil
end

function H.no_warnings(list)
  for _, n in ipairs(list) do
    if n.level and n.level >= vim.log.levels.WARN then
      error("unexpected warning/error notification: " .. n.msg, 2)
    end
  end
end

-- ------------------------------------------------------------- ui stubs

-- vim.ui.select / vim.ui.input drive every wizard in this layer. Stub them with
-- a scripted set of answers so the flows can run headless.
--
-- answers: list of values. For select, a value may be a number (1-based index),
-- a string (matched against the formatted label) or a function(items)->item.
-- `nil` as an answer means "user cancelled" -- use H.CANCEL, since a nil in a
-- Lua list would end it.
H.CANCEL = setmetatable({}, { __tostring = function() return "<cancel>" end })

function H.stub_ui(answers)
  local orig_select, orig_input = vim.ui.select, vim.ui.input
  local i = 0
  local log = {}
  local function next_answer(kind, prompt, default)
    i = i + 1
    -- `default` is what the box is prefilled with, which is the whole answer
    -- to "what does the wizard offer me?" -- assertable only if recorded.
    log[#log + 1] = { kind = kind, prompt = prompt, index = i, default = default }
    if i > #answers then
      error(("ui.%s asked for answer #%d (%s) but only %d were scripted")
        :format(kind, i, tostring(prompt), #answers), 0)
    end
    return answers[i]
  end

  vim.ui.select = function(items, opts, on_choice)
    local a = next_answer("select", opts and opts.prompt)
    if a == H.CANCEL then return on_choice(nil) end
    if type(a) == "function" then return on_choice(a(items)) end
    if type(a) == "number" then return on_choice(items[a], a) end
    local format = (opts and opts.format_item) or tostring
    for idx, item in ipairs(items) do
      if format(item) == a or (type(item) == "string" and item == a) then
        return on_choice(item, idx)
      end
    end
    -- fall back to a substring match on the formatted label
    for idx, item in ipairs(items) do
      if tostring(format(item)):find(a, 1, true) then return on_choice(item, idx) end
    end
    error(("ui.select: no item matching %q (had: %s)"):format(a,
      table.concat(vim.tbl_map(function(x) return tostring(format(x)) end, items), " | ")), 0)
  end

  vim.ui.input = function(opts, on_confirm)
    local a = next_answer("input", opts and opts.prompt, opts and opts.default)
    if a == H.CANCEL then return on_confirm(nil) end
    if a == H.DEFAULT then return on_confirm(opts and opts.default) end
    return on_confirm(a)
  end

  return {
    log = log,
    restore = function()
      vim.ui.select, vim.ui.input = orig_select, orig_input
    end,
    consumed = function() return i end,
  }
end

H.DEFAULT = setmetatable({}, { __tostring = function() return "<default>" end })

-- Run fn with scripted ui answers, always restoring the originals.
function H.with_ui(answers, fn)
  local s = H.stub_ui(answers)
  local ok, err = pcall(fn, s)
  s.restore()
  if not ok then error(err, 0) end
  return s
end

-- ------------------------------------------------------------- scratch dirs

H.scratch_root = os.getenv("KEBAB_TEST_SCRATCH") or (vim.fn.tempname() .. "-kebab")

local counter = 0
function H.tmpdir(label)
  counter = counter + 1
  local d = ("%s/%03d-%s"):format(H.scratch_root, counter, (label or "t"):gsub("[^%w%-]", "_"))
  vim.fn.mkdir(d, "p")
  return d
end

-- A real git repo with one commit, so git operations have a HEAD to work from.
function H.git_repo(label)
  local d = H.tmpdir(label or "repo")
  local function git(...)
    local cmd = { "git", "-C", d }
    vim.list_extend(cmd, { ... })
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      error("git " .. table.concat({ ... }, " ") .. " failed: " .. out, 2)
    end
    return out
  end
  git("init", "-q", "-b", "main")
  git("config", "user.email", "test@example.com")
  git("config", "user.name", "kebab test")
  git("config", "commit.gpgsign", "false")
  vim.fn.writefile({ "# " .. vim.fn.fnamemodify(d, ":t") }, d .. "/README.md")
  git("add", "README.md")
  git("commit", "-q", "-m", "initial")
  return d, git
end

function H.read(path) return table.concat(vim.fn.readfile(path), "\n") end
function H.write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n"), path)
end
function H.exists(path) return vim.uv.fs_stat(path) ~= nil end

-- Wait until cond() is true, or fail. Everything async in this layer resolves
-- through vim.schedule, so a bare assertion right after the call races it.
function H.wait(ms, cond, msg)
  local ok = vim.wait(ms, cond, 50)
  if not ok then error("timed out after " .. ms .. "ms waiting for " .. (msg or "condition"), 2) end
  return true
end

-- Let queued vim.schedule callbacks run.
function H.drain(ms) vim.wait(ms or 50, function() return false end, 10) end

---Put the editor back to one window holding one empty, modifiable buffer.
---
---Called between spec files by tests/run.lua. Specs leak editor state more
---readily than you would think: opening any real file fires the explorer
---autocmd and leaves a neo-tree window, and landing on neo-tree's buffer makes
---the next spec's `enew!` fail with "Buffer is not 'modifiable'". Isolating at
---the framework level is better than every spec remembering to tidy up.
---The directory specs must be left in, set by tests/run.lua.
H.sandbox = nil

function H.reset_editor()
  -- Stop the follower. A spec that leaves it running leaves an inotifywait
  -- process behind, and its callbacks move the *next* spec's buffers around.
  pcall(function()
    local F = package.loaded["kebab.follow"]
    if F then
      F.stop()
      if F.allow_autostart then
        F.allow_autostart()
      end
    end
  end)

  pcall(vim.cmd, "silent! only")

  -- Back to the sandbox. A spec that cd's somewhere to exercise a cwd-relative
  -- path left every later spec running there -- and run.lua only cd's once, at
  -- startup, so the leak was permanent.
  if H.sandbox and vim.fn.getcwd() ~= H.sandbox then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(H.sandbox))
  end

  -- A scratch buffer first, so wiping the others cannot leave us nowhere.
  local scratch = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_set_current_buf, scratch)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= scratch and vim.api.nvim_buf_is_valid(buf) then
      -- `modified` buffers refuse to close without the bang, and a few
      -- plugin buffers refuse regardless; neither should fail a test run.
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  pcall(vim.cmd, "silent! enew!")
  vim.bo.modifiable = true
  vim.bo.modified = false
end

function H.report()
  io.write("\n")
  if results.fail > 0 then
    io.write(("%d failing:\n"):format(results.fail))
    for _, f in ipairs(results.failures) do
      io.write("  - " .. f.label .. "\n")
    end
  end
  io.write(("\n%d passed, %d failed, %d skipped\n"):format(results.pass, results.fail, results.skip))
  return results
end

H.results = results
return H
