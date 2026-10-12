-- A file the editor cannot show goes to the desktop.
--
-- Double clicking `logo.png` in the tree used to load the PNG's bytes into a
-- buffer: mojibake, a buffer to find and close, and no image. Asked for
-- directly -- "when user double click some image files or pdf or any other
-- file which is not text based ... make the OS open it with its default app".
--
-- Nothing here launches an image viewer: `M.open` takes the spawn function, so
-- what is asserted is the argv it would have run.
local H = ...

local X = require("kebab.openexternal")

---Write bytes (which may contain a NUL) to a path. vim.fn.writefile turns a
---Lua string holding a NUL into a Blob and raises E974, so this goes through
---libuv.
local function write_bytes(path, bytes)
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  vim.uv.fs_write(fd, bytes, 0)
  vim.uv.fs_close(fd)
  return path
end

---Run fn with a configuration pinned, then put the global back. A spec must
---never read the ambient value: the author's own config is live during a run.
local function with_config(config, fn)
  local saved = vim.g.kebab_open_external
  vim.g.kebab_open_external = config
  local ok, err = pcall(fn)
  vim.g.kebab_open_external = saved
  if not ok then
    error(err, 0)
  end
end

H.describe("deciding what the desktop should open", function()
  H.it("takes the types a viewer exists for", function()
    local dir = H.tmpdir("ext-yes")
    for _, name in ipairs({ "logo.png", "report.pdf", "clip.mp4", "sheet.xlsx", "bundle.zip" }) do
      write_bytes(dir .. "/" .. name, "some bytes")
      local external, why = X.is_external(dir .. "/" .. name)
      H.ok(external, name .. " should go to the desktop")
      H.eq("extension", why)
    end
  end)

  H.it("leaves text alone, including the text that looks like an image", function()
    local dir = H.tmpdir("ext-no")
    -- .svg and .xml are text you edit as often as you look at, and a JSON or
    -- SQL file is never anything else.
    for _, name in ipairs({ "icon.svg", "pom.xml", "data.json", "query.sql", "notes.md", "Makefile" }) do
      write_bytes(dir .. "/" .. name, "<text>\n")
      H.falsy(X.is_external(dir .. "/" .. name, { sniff = true }), name .. " belongs in the editor")
    end
  end)

  H.it("is case-insensitive about the extension", function()
    local dir = H.tmpdir("ext-case")
    write_bytes(dir .. "/SCAN.PDF", "%PDF")
    H.ok(X.is_external(dir .. "/SCAN.PDF"))
  end)

  H.it("does not take a directory, or a path that is not there", function()
    local dir = H.tmpdir("ext-dir")
    vim.fn.mkdir(dir .. "/pictures.zip", "p") -- a directory named like an archive
    H.falsy(X.is_external(dir .. "/pictures.zip"), "a directory is the tree's business")
    H.falsy(X.is_external(dir .. "/not-here.png"), "nothing to open")
    H.falsy(X.is_external(""), "an unnamed buffer has no file")
  end)

  H.it("catches an unknown binary only when asked to sniff", function()
    -- The tree can afford this: the path is in hand and nothing has read the
    -- file, so it is a 1 KB read. The BufReadCmd cannot -- a pattern has to be
    -- known before the file is seen.
    local dir = H.tmpdir("ext-sniff")
    local bin = write_bytes(dir .. "/payload.bin", "\127ELF\0\1\2\3 and more")
    local external, why = X.is_external(bin, { sniff = true })
    H.ok(external, "a NUL in the first kilobyte is not text")
    H.eq("binary", why)
    H.falsy(X.is_external(bin), "without sniffing it is just an unknown extension")
  end)

  H.it("can be turned off, extended and replaced", function()
    local dir = H.tmpdir("ext-config")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    local blend = write_bytes(dir .. "/scene.kra", "bytes")

    with_config(false, function()
      H.falsy(X.is_external(png), "vim.g.kebab_open_external = false turns it off")
    end)
    with_config({ extensions = { "kra" } }, function()
      H.ok(X.is_external(blend), "an added extension is taken")
      H.ok(X.is_external(png), "and the defaults are still there -- a list is merged, not replaced")
    end)
    with_config({ extensions = { "kra" }, replace_extensions = true }, function()
      H.ok(X.is_external(blend))
      H.falsy(X.is_external(png), "replace_extensions means only what was given")
    end)
    with_config({ sniff = false }, function()
      H.falsy(X.is_external(write_bytes(dir .. "/x.bin", "\0\0"), { sniff = true }))
    end)
  end)
end)

H.describe("handing a file to the desktop", function()
  H.it("runs the platform's opener with the path", function()
    -- The only test here that needs a real one. A machine with no xdg-open is
    -- legitimate -- `kebab doctor` lists it as optional -- and a container
    -- without xdg-utils is what caught this: three tests failed for want of a
    -- desktop rather than for want of correct code.
    local argv, why = X.opener()
    if not argv then
      H.skip(why or "no desktop opener on this machine")
    end
    local dir = H.tmpdir("ext-open")
    local pdf = write_bytes(dir .. "/report.pdf", "%PDF-1.7")
    local seen
    local notes = H.capture_notify(function()
      X.open(pdf, { spawn = function(argv) seen = argv return {} end })
    end)
    H.ok(seen ~= nil, "it should have spawned something")
    H.eq(pdf, seen[#seen], "the path is the last argument")
    H.ok(vim.tbl_contains({ "xdg-open", "open", "cmd.exe", "gio", "handlr" }, seen[1]),
      "unexpected opener: " .. tostring(seen[1]))
    H.matches("report%.pdf", table.concat(vim.tbl_map(function(n) return n.msg end, notes), " "),
      "it says which file it handed over")
    H.no_warnings(notes)
  end)

  H.it("uses a configured opener instead", function()
    local dir = H.tmpdir("ext-cmd")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    local seen
    with_config({ command = { "sh", "-c", "true" }, notify = false }, function()
      X.open(png, { spawn = function(argv) seen = argv return {} end })
    end)
    H.eq({ "sh", "-c", "true", png }, seen)
  end)

  H.it("reports a configured opener that is not installed, and falls back", function()
    local dir = H.tmpdir("ext-missing")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    local fell_back = false
    with_config({ command = { "definitely-not-installed-opener" } }, function()
      local started, err = X.open(png, {
        spawn = function() error("should not be reached") end,
        fallback = function() fell_back = true end,
      })
      H.falsy(started)
      H.matches("not on PATH", tostring(err))
    end)
    H.ok(fell_back, "the editor has to get the file when the desktop cannot")
  end)

  H.it("falls back when the spawn itself throws", function()
    -- vim.system throws ENOENT for a missing executable rather than returning
    -- a code, which is the trap deps.lua and scaffold.lua already guard.
    --
    -- `sh` as the configured opener, not the platform's: this is about what
    -- happens when the spawn throws, and on a machine with no xdg-open the
    -- function returned before ever reaching the spawn -- so the test failed
    -- with "no desktop opener found" and proved nothing about the throw.
    local dir = H.tmpdir("ext-throw")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    local reason, started
    with_config({ command = { "sh" }, notify = false }, function()
      started = X.open(png, {
        spawn = function() error("ENOENT: no such file or directory") end,
        fallback = function(why) reason = why end,
      })
    end)
    H.falsy(started)
    H.matches("ENOENT", tostring(reason))
  end)

  H.it("handle() only takes what it should", function()
    local dir = H.tmpdir("ext-handle")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    local txt = write_bytes(dir .. "/notes.txt", "hello")
    local calls = 0
    local spawn = function() calls = calls + 1 return {} end
    -- a configured opener, so the count is about the decision and not about
    -- whether this machine has a desktop
    with_config({ command = { "sh" }, notify = false }, function()
      H.ok(X.handle(png, { spawn = spawn }))
      H.falsy(X.handle(txt, { spawn = spawn }))
    end)
    H.eq(1, calls, "the text file must not be handed to the desktop")
  end)
end)

H.describe("the tree's open commands", function()
  local commands = X.neotree_commands()

  H.it("covers every way the tree opens a file", function()
    -- <CR>, a double click and the right-click menu's "Open" all dispatch
    -- through `open`; the splits and the tab are the same decision.
    for _, name in ipairs({ "open", "open_split", "open_vsplit", "open_tabnew" }) do
      H.ok(type(commands[name]) == "function", name .. " should be overridden")
    end
  end)

  H.it("hands an image to the desktop instead of the editor", function()
    local dir = H.tmpdir("ext-tree")
    local png = write_bytes(dir .. "/logo.png", "bytes")
    -- the shape neo-tree passes: a state whose tree answers get_node()
    local state = { tree = { get_node = function() return { type = "file", path = png } end } }
    with_config({ command = { "sh", "-c", "true" }, notify = false }, function()
      -- The command resolves the spawn through M.handle, so the only way to
      -- avoid launching something here is a configured opener that does
      -- nothing. `sh -c true` is that.
      commands.open(state)
    end)
    -- and no buffer was opened for it
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      H.falsy(vim.api.nvim_buf_get_name(b):find("logo%.png"), "the tree must not open the image in a buffer")
    end
  end)

  H.it("passes a text file through to neo-tree", function()
    local dir = H.tmpdir("ext-tree-text")
    local lua = write_bytes(dir .. "/init.lua", "local x = 1\n")
    local state = { tree = { get_node = function() return { type = "file", path = lua } end } }
    local notes = H.capture_notify(function()
      pcall(commands.open, state)
    end)
    -- What matters is that it reached neo-tree rather than the desktop: outside
    -- a tree window neo-tree's own command is what fails, and it must be the
    -- thing that answers.
    local text = table.concat(vim.tbl_map(function(n) return n.msg end, notes), " ")
    H.falsy(text:find("system default"), "a Lua file is not the desktop's business")
  end)

  H.it("leaves a directory to neo-tree", function()
    local dir = H.tmpdir("ext-tree-dir")
    local state = { tree = { get_node = function() return { type = "directory", path = dir } end } }
    local notes = H.capture_notify(function()
      pcall(commands.open, state)
    end)
    local text = table.concat(vim.tbl_map(function(n) return n.msg end, notes), " ")
    H.falsy(text:find("system default"), "opening a directory toggles it")
  end)
end)

H.describe("the live tree", function()
  H.it("really dispatches its open command to this module", function()
    -- Configured is not wired. neo-tree merges a *top-level* `commands` table
    -- with tbl_extend("keep", ...) **under** the source's own, so an `open`
    -- declared there would be silently ignored -- the override has to be in
    -- `opts.filesystem.commands`, and the only way to know it took is to ask
    -- the state the renderer actually dispatches through.
    pcall(function()
      require("lazy").load({ plugins = { "neo-tree.nvim" } })
    end)
    local dir = H.tmpdir("ext-live")
    pcall(function()
      require("neo-tree.command").execute({ action = "show", dir = dir })
    end)
    local manager = require("neo-tree.sources.manager")
    vim.wait(8000, function()
      local state = manager.get_state("filesystem")
      return state ~= nil and state.commands ~= nil
    end, 50)
    local state = manager.get_state("filesystem")
    H.ok(state ~= nil and state.commands ~= nil, "neo-tree never produced a filesystem state")
    local where = debug.getinfo(state.commands.open, "S").short_src or ""
    H.matches("kebab/openexternal%.lua", where,
      "the tree's open command should be this layer's, not neo-tree's own")
  end)
end)

H.describe("the autocmd", function()
  H.it("is registered for the extensions, by BufReadCmd", function()
    -- BufReadCmd rather than BufReadPre: it replaces the read, so a 4 GB video
    -- is never loaded in order to decide not to look at it.
    local found = {}
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "BufReadCmd" })) do
      if au.group_name == "kebab_open_external" then
        found[#found + 1] = au.pattern
      end
    end
    H.ok(#found > 0, "no BufReadCmd registered -- did explorer.setup() run?")
    H.ok(vim.tbl_contains(found, "*.png"), "*.png should be one of the patterns")
    H.ok(vim.tbl_contains(found, "*.pdf"), "*.pdf should be one of the patterns")
    H.ok(vim.tbl_contains(found, "*.PNG"), "an upper-case extension is the same file")
    H.falsy(vim.tbl_contains(found, "*.lua"), "text must not be intercepted")
  end)
end)
