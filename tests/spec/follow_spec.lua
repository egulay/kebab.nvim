-- Following edits made outside the editor.
local H = ...
local F = require("kebab.follow")

local function with_config(cfg, fn)
  local saved = vim.g.kebab_follow
  vim.g.kebab_follow = cfg
  local ok, err = pcall(fn)
  vim.g.kebab_follow = saved
  if not ok then error(err, 0) end
end

H.describe("what is ignored", function()
  H.it("follows source files", function()
    for _, p in ipairs({ "/p/src/Main.java", "/p/lib/main.dart", "/p/a.py", "/p/go.mod" }) do
      H.eq(false, F.ignored(p), p .. " should be followed")
    end
  end)

  H.it("ignores build output, which would drown the signal", function()
    -- A Maven build rewrites thousands of files under target/.
    for _, p in ipairs({
      "/p/target/classes/X.class", "/p/build/out.js", "/p/node_modules/a/b.js",
      "/p/.git/index", "/p/dist/app.js", "/p/.venv/lib/x.py", "/p/__pycache__/a.pyc",
      "/p/.gradle/x", "/p/.dart_tool/y", "/p/.svelte-kit/z",
    }) do
      H.eq(true, F.ignored(p), p .. " should be ignored")
    end
  end)

  H.it("matches whole path segments only", function()
    -- a project called build-tools is not the build directory
    H.eq(false, F.ignored("/p/build-tools/x.lua"))
    H.eq(false, F.ignored("/p/src/targeting/aim.go"))
    H.eq(false, F.ignored("/p/distribution/readme.md"))
  end)

  H.it("ignores editor and temporary noise", function()
    for _, p in ipairs({ "/p/a.swp", "/p/a~", "/p/a.tmp", "/p/x.part", "/p/a.log", "/p/4913" }) do
      H.eq(true, F.ignored(p), p .. " should be ignored")
    end
  end)

  H.it("ignores its own state directory", function()
    H.eq(true, F.ignored("/p/.kebab/run.json"))
  end)

  H.it("ignores nothing useful by accident", function()
    H.eq(true, F.ignored(""))
    H.eq(true, F.ignored(nil))
  end)

  H.it("takes extra ignores from the config", function()
    with_config({ ignored_dirs = { "generated" } }, function()
      H.eq(true, F.ignored("/p/generated/x.go"))
    end)
  end)
end)

H.describe("yielding to the user", function()
  H.it("follows when nothing is in the way", function()
    H.reset_editor()
    H.eq(nil, F.yielding())
  end)

  H.it("yields while the buffer has unsaved changes", function()
    H.reset_editor()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "typing" })
    vim.bo.modified = true
    H.matches("unsaved changes", F.yielding())
    vim.bo.modified = false
  end)

  H.it("yields in a terminal buffer", function()
    H.reset_editor()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype = "prompt"
    H.matches("terminal or prompt", F.yielding())
    H.reset_editor()
  end)

  H.it("yields with a picker open", function()
    H.reset_editor()
    vim.bo.filetype = "TelescopePrompt"
    H.matches("picker open", F.yielding())
    H.reset_editor()
  end)
end)

H.describe("finding the change", function()
  H.it("reports the first differing line", function()
    H.eq(2, F.first_change({ "a", "b", "c" }, { "a", "B", "c" }))
    H.eq(1, F.first_change({ "a" }, { "z" }))
  end)

  H.it("reports nothing when identical", function()
    H.eq(nil, F.first_change({ "a", "b" }, { "a", "b" }))
    H.eq(nil, F.first_change({}, {}))
  end)

  H.it("reports an append and a truncation", function()
    H.eq(2, F.first_change({ "a" }, { "a", "b" }))
    H.eq(2, F.first_change({ "a", "b" }, { "a" }))
  end)
end)

H.describe("locating the buffer for a path", function()
  H.it("finds a file that is open", function()
    local path = H.tmpdir("follow-buf") .. "/open.txt"
    H.write(path, "one")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = F.buffer_for(path)
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.reset_editor()
  end)

  H.it("finds nothing for a file that is not open", function()
    H.eq(nil, F.buffer_for(H.tmpdir("follow-none") .. "/absent.txt"))
  end)
end)

H.describe("following a change", function()
  H.it("reloads the buffer and moves the cursor to the changed line", function()
    local path = H.tmpdir("follow-jump") .. "/code.txt"
    H.write(path, "line one\nline two\nline three\nline four")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    H.reset_editor()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- changed by something else, as an agent would
    local res = vim.system({ "sh", "-c",
      ("printf 'line one\\nline two\\nCHANGED BY AGENT\\nline four\\n' > %q"):format(path) })
      :wait(20000)
    H.eq(0, res.code)

    local line = F.follow_file(path)
    H.eq(3, line, "it should land on the line that changed")
    H.eq(3, vim.api.nvim_win_get_cursor(0)[1], "and move the cursor there")
    H.matches("CHANGED BY AGENT", vim.api.nvim_buf_get_lines(0, 2, 3, false)[1],
      "and the buffer should show the new content")
    H.reset_editor()
  end)

  H.it("refuses to reload over unsaved changes", function()
    -- The one thing it must never do: discard either side of a conflict.
    local path = H.tmpdir("follow-conflict") .. "/code.txt"
    H.write(path, "original")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my own edit" })
    vim.bo.modified = true

    vim.system({ "sh", "-c", ("printf 'theirs\\n' > %q"):format(path) }):wait(20000)

    local notes = H.capture_notify(function()
      local line, reason = F.follow_file(path)
      H.eq(nil, line)
      H.eq("conflict", reason)
    end)
    H.ok(H.notified(notes, "unsaved changes"), "it should say why it did not reload")
    H.eq("my own edit", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
      "my edit must survive")
    vim.bo.modified = false
    H.reset_editor()
  end)

  -- Pinned, not ambient. The suite boots the real user config on purpose, so a
  -- spec asserting a *default* has to set it: this failed the moment the
  -- author's own config set `open_new = true`, which is a legitimate thing to
  -- want and not a regression in the layer.
  H.it("leaves a file that is not open alone when open_new is off", function()
    with_config({ open_new = false }, function()
      local path = H.tmpdir("follow-closed") .. "/new.txt"
      H.write(path, "appeared")
      local line, reason = F.follow_file(path)
      H.eq(nil, line)
      H.eq("not open", reason, "an agent writing 40 files should not open 40 buffers")
    end)
  end)

  H.it("ships with open_new off, whatever this machine's config says", function()
    -- the declared default, read with the user's config neutralised
    local saved = vim.g.kebab_follow
    vim.g.kebab_follow = nil
    local default = F.config().open_new
    vim.g.kebab_follow = saved
    H.eq(false, default, "the shipped default is off; a config may turn it on")
  end)

  H.it("opens a new file when asked to", function()
    local path = H.tmpdir("follow-open") .. "/new.txt"
    H.write(path, "appeared")
    with_config({ open_new = true }, function()
      local line = F.follow_file(path)
      H.eq(1, line)
      H.matches("new%.txt$", vim.api.nvim_buf_get_name(0))
    end)
    H.reset_editor()
  end)
end)

H.describe("coalescing a burst", function()
  ---Run `fn` while following a scratch directory.
  local function following(fn)
    local dir = H.tmpdir("burst")
    local ok, err = F.start(dir)
    if not ok then
      H.skip("could not start a watcher: " .. tostring(err))
    end
    local ran, rerr = pcall(fn, dir)
    F.stop()
    if not ran then
      error(rerr, 0)
    end
  end

  H.it("records a change worth following", function()
    following(function()
      H.eq(true, F.on_change("/p/src/Main.java"))
    end)
  end)

  H.it("drops an ignored path without arming the timer", function()
    following(function()
      H.eq(false, F.on_change("/p/target/x.class"))
    end)
  end)

  -- STATE.stop_fn is an asynchronous SIGINT, so whatever inotifywait had
  -- already written is still delivered after stop() returns. Acting on it
  -- moved the view after the user turned following off, and armed a debounce
  -- timer that stop() could never close -- one leaked libuv handle per
  -- stop-mid-burst, for the rest of the session.
  H.it("ignores an event that arrives after stop", function()
    H.falsy(F.running(), "this starts from off")
    H.eq(false, F.on_change("/p/src/Main.java"), "a change with nothing watching is not ours")
    H.falsy(F.cancel_timer(), "and no timer should have been armed")
  end)

  H.it("has a debounce window, so a 40-file refactor is watchable", function()
    local cfg = F.config()
    H.ok(cfg.debounce_ms >= 100, "a per-event jump would be unwatchable")
    H.eq("latest", cfg.follow)
  end)

  H.it("can be told to stay on the first file of a burst instead", function()
    with_config({ follow = "first" }, function()
      H.eq("first", F.config().follow)
    end)
  end)
end)

H.describe("the watcher", function()
  H.it("is off by default", function()
    H.eq(false, F.running())
    H.eq("", F.status(), "nothing in the statusline when off")
  end)

  H.it("starts and stops", function()
    local dir = H.tmpdir("follow-watch")
    local ok, err = F.start(dir)
    H.ok(ok, tostring(err))
    H.eq(true, F.running())
    H.matches("following", F.status())
    H.eq(dir, F.state().root)

    H.eq(false, (F.start(dir)), "starting twice should be refused")

    H.ok(F.stop())
    H.eq(false, F.running())
    H.eq(false, (F.stop()), "stopping twice should be refused")
  end)

  H.it("picks up a real external write", function()
    -- End to end through inotify: the watcher must see a change made by
    -- another process, not just one this process made.
    local dir = H.tmpdir("follow-live")
    local path = dir .. "/watched.txt"
    H.write(path, "before")
    local ok, err = F.start(dir)
    H.ok(ok, tostring(err))

    vim.system({ "sh", "-c", ("printf 'after\\n' >> %q"):format(path) }):wait(20000)

    local seen = vim.wait(10000, function()
      return F.state().pending > 0 or F.state().count > 0
    end, 100)
    F.stop()
    H.ok(seen, "the watcher should have noticed the write")
  end)

  H.it("reports what it is doing", function()
    local s = F.state()
    H.eq("boolean", type(s.running))
    H.eq("number", type(s.count))
  end)
end)

H.describe("the follow commands", function()
  H.it("are registered", function()
    H.ok(vim.fn.exists(":IdeFollow") >= 1)
    H.ok(vim.fn.exists(":IdeFollowStatus") >= 1)
  end)

  H.it("toggles on and off", function()
    local notes = H.capture_notify(function()
      F.toggle()
    end)
    H.ok(H.notified(notes, "Follow: on"), "it should say it started")
    H.eq(true, F.running())
    notes = H.capture_notify(function()
      F.toggle()
    end)
    H.ok(H.notified(notes, "Follow: off"))
    H.eq(false, F.running())
  end)
end)

-- The two follow modes were effectively swapped and sorted by name:
-- STATE.pending was a plain set, so insertion order was irrecoverable and
-- table.sort made "latest" mean "alphabetically last".
H.describe("which file of a burst wins", function()
  local function burst(mode, order)
    local dir = H.tmpdir("burst-order-" .. mode)
    vim.fn.mkdir(dir .. "/src", "p")
    for _, name in ipairs(order) do
      H.write(dir .. "/src/" .. name, name)
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/src/" .. name))
    end
    local saved = vim.g.kebab_follow
    vim.g.kebab_follow = { follow = mode, debounce_ms = 20 }
    local ok, err = F.start(dir)
    if not ok then
      vim.g.kebab_follow = saved
      H.skip("could not start a watcher: " .. tostring(err))
    end
    for _, name in ipairs(order) do
      F.on_change(dir .. "/src/" .. name)
    end
    H.wait(3000, function()
      return F.state().pending == 0
    end, "the burst should flush")
    local landed = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
    F.stop()
    vim.g.kebab_follow = saved
    return landed
  end

  -- zebra changes first, alpha second: name order and arrival order disagree
  H.it("'latest' follows the most recent change, not the last by name", function()
    H.eq("alpha.txt", burst("latest", { "zebra.txt", "alpha.txt" }))
  end)

  H.it("'first' follows the first change, not the first by name", function()
    H.eq("zebra.txt", burst("first", { "zebra.txt", "alpha.txt" }))
  end)
end)

-- tbl_deep_extend REPLACES a list rather than merging it, so setting one entry
-- un-ignored node_modules, build, .venv and the rest -- and un-ignoring .swp
-- made the follower chase Vim's own swap writes.
H.describe("configuring the ignore lists", function()
  H.it("adds to the built-in list rather than replacing it", function()
    with_config({ ignored_dirs = { "generated" } }, function()
      local cfg = F.config()
      H.ok(vim.tbl_contains(cfg.ignored_dirs, "generated"), "the new entry should be there")
      H.ok(vim.tbl_contains(cfg.ignored_dirs, "node_modules"), "and so should the built-ins")
      H.ok(F.ignored("/p/node_modules/a/b.js"), "node_modules must still be ignored")
      H.ok(F.ignored("/p/build/out.js"))
      H.ok(F.ignored("/p/generated/x.js"), "and the new one too")
    end)
  end)

  H.it("keeps ignoring swap files when a suffix is added", function()
    with_config({ ignored_suffixes = { ".bak" } }, function()
      H.ok(F.ignored("/p/a.swp"), "or the follower chases its own swap writes")
      H.ok(F.ignored("/p/a.bak"))
      H.ok(F.ignored("/p/a.class"))
    end)
  end)

  H.it("can still be told to replace them outright", function()
    with_config({ replace_ignores = true, ignored_dirs = { "only" }, ignored_suffixes = {} }, function()
      H.falsy(F.ignored("/p/node_modules/a.js"), "an explicit opt-out has to be possible")
      H.ok(F.ignored("/p/only/a.js"))
    end)
  end)
end)

-- Having to press <leader>uf in every session is how you end up believing the
-- feature does not work at all. The flag is read inside the callback, never at
-- setup time: setup() is called from another spec's `init`, and lazy does not
-- order `init` functions -- deciding early meant the autocmd was never
-- registered whenever that init ran before the one setting the flag.
H.describe("starting itself", function()
  local function with_autostart(value, fn)
    local saved = vim.g.kebab_follow_autostart
    vim.g.kebab_follow_autostart = value
    -- Within one session an earlier start, or an earlier deliberate stop, both
    -- latch -- which is the point of them. A test asking "would it start?"
    -- needs the same fresh decision a new project gets.
    F.allow_autostart()
    local ok, err = pcall(fn)
    vim.g.kebab_follow_autostart = saved
    pcall(F.stop)
    F.allow_autostart()
    if not ok then
      error(err, 0)
    end
  end

  H.it("registers its autocmds whatever the flag was at setup time", function()
    -- setup() runs with the flag unset, which is the ordering that used to
    -- lose the autocmd entirely
    local saved = vim.g.kebab_follow_autostart
    vim.g.kebab_follow_autostart = nil
    F.setup()
    vim.g.kebab_follow_autostart = saved

    local aus = vim.api.nvim_get_autocmds({ group = "kebab_follow" })
    local events = {}
    for _, a in ipairs(aus) do
      events[a.event] = true
    end
    H.ok(events["VimLeavePre"], "the watcher must still be stopped on exit")
    H.ok(events["DirChanged"], "opening another project should re-point it")
    H.ok(
      events["VimEnter"] or events["BufEnter"],
      "it needs a start trigger: " .. vim.inspect(vim.tbl_keys(events))
    )
  end)

  H.it("does nothing when the flag is off", function()
    with_autostart(nil, function()
      H.falsy(F.running())
      vim.api.nvim_exec_autocmds("BufEnter", { modeline = false })
      H.drain(200)
      H.falsy(F.running(), "it must stay off unless asked for")
    end)
  end)

  H.it("starts without a keypress when the flag is on", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to start a watcher")
    end
    with_autostart(true, function()
      H.falsy(F.running(), "this starts from off")
      vim.api.nvim_exec_autocmds("BufEnter", { modeline = false })
      local started = vim.wait(10000, function()
        return F.running()
      end, 100)
      H.ok(started, "the autocmd should have started it")
      H.ok(#F.state().roots > 0, "and it should be watching something")
    end)
  end)
end)

H.describe("watching more than one project", function()
  -- A watcher only ever sees its own tree, so following the project you have
  -- open cannot show you an agent working somewhere else -- which is the one
  -- thing this feature exists for.
  H.it("resolves the project root plus any named extras", function()
    local a = H.tmpdir("roots-a")
    local b = H.tmpdir("roots-b")
    local saved = vim.g.kebab_follow_roots
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(a))

    vim.g.kebab_follow_roots = nil
    H.eq({ vim.fn.resolve(a) }, vim.tbl_map(vim.fn.resolve, F.roots()), "just the project by default")

    vim.g.kebab_follow_roots = { b }
    local both = vim.tbl_map(vim.fn.resolve, F.roots())
    H.eq(2, #both, vim.inspect(both))
    H.ok(vim.tbl_contains(both, vim.fn.resolve(b)), "the named project should be included")

    -- a root that does not exist is dropped rather than failing the start
    vim.g.kebab_follow_roots = { b, "/nonexistent-kebab-root-xyz" }
    H.eq(2, #F.roots(), "a missing root is skipped")

    -- and an explicit argument still wins, which is what the specs above use
    H.eq({ a }, F.roots(a))

    vim.g.kebab_follow_roots = saved
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  end)

  -- The wiring, asserted deterministically. Racing a real inotify event in the
  -- full suite is not: the event loop is busy with language servers and the
  -- watcher's own delivery is asynchronous, so this raced about one run in
  -- three. The end-to-end jump is already covered by the single-root tests
  -- above, which exercise the identical flush path.
  H.it("watches a project it was told about, and accepts its changes", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to start a watcher")
    end
    local mine = H.tmpdir("two-mine")
    local other = H.tmpdir("two-other")
    H.write(mine .. "/a.txt", "mine")
    local saved_roots = vim.g.kebab_follow_roots
    local saved_cfg = vim.g.kebab_follow
    vim.g.kebab_follow_roots = { other }
    vim.g.kebab_follow = { open_new = true, debounce_ms = 100 }

    local ok, err = pcall(function()
      vim.cmd("edit " .. vim.fn.fnameescape(mine .. "/a.txt"))
      H.ok(F.start(), "it should watch both")
      local roots = vim.tbl_map(vim.fn.resolve, F.state().roots)
      H.eq(2, #roots, vim.inspect(roots))
      H.ok(vim.tbl_contains(roots, vim.fn.resolve(other)), "the named project should be watched")

      -- a path in the other project is ours to act on, not ignored
      local appeared = other .. "/appeared.txt"
      H.write(appeared, "written by something else")
      H.eq(true, F.on_change(appeared), "a change there must be accepted")
      H.falsy(F.ignored(appeared), "and not filtered out")
    end)
    pcall(F.stop)
    vim.g.kebab_follow_roots = saved_roots
    vim.g.kebab_follow = saved_cfg
    H.reset_editor()
    H.ok(ok, tostring(err))
  end)
end)
