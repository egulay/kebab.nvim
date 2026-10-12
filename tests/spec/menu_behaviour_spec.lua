-- Behavioural half of the editor-menu sweep.
--
-- menu_editor_spec proves every entry's target *exists*. That is necessary and
-- not sufficient: the rule in this repo is that "the menu renders" was never the
-- same as "the entries do anything". These tests run the entries that have an
-- observable effect and assert on the effect.
local H = ...
local A = require("kebab.menus.action")
local menus = require("kebab.menus.editor")

---Fetch an entry's cmd by menu path, e.g. find("Edit", "Select All").
local function find(menu_name, entry_name, sub)
  for _, m in ipairs(menus) do
    if m.name == menu_name then
      local items = m.items
      if sub then
        for _, e in ipairs(items) do
          if e.name == sub then items = e.items break end
        end
      end
      for _, e in ipairs(items) do
        if e.name == entry_name then return e end
      end
    end
  end
  error(("no menu entry %s › %s%s"):format(menu_name, sub and (sub .. " › ") or "", entry_name), 2)
end

---Run an entry the way nvzone/menu does: string -> vim.cmd, else call it.
local function activate(entry)
  if type(entry.cmd) == "string" then
    vim.cmd(entry.cmd)
  else
    entry.cmd()
  end
end

-- Tests accumulate windows: the explorer autocmd opens neo-tree on every
-- BufReadPost, and Trouble and Aerial each add their own. Collapsing back to a
-- single window keeps each test independent of what the last one left behind.
local function only_window()
  pcall(vim.cmd, "silent! only")
end

local function scratch_buf(lines)
  only_window()
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { "alpha", "beta", "gamma" })
  return vim.api.nvim_get_current_buf()
end

H.describe("menu behaviour", function()
  H.it("Project › Keymap Cheatsheet opens the cheatsheet that ships with the repo", function()
    -- This is the bug the sweep found: the entry pointed at an absolute
    -- ~/.config/nvim/IDE-CHEATSHEET.md that has never existed.
    local notes = H.capture_notify(function()
      activate(find("Project", "Keymap Cheatsheet"))
    end)
    H.no_warnings(notes)
    local name = vim.api.nvim_buf_get_name(0)
    H.matches("CHEATSHEET%.md$", name, "should have opened CHEATSHEET.md")
    H.ok(vim.uv.fs_stat(name), "the opened file must actually exist")
    H.ok(vim.api.nvim_buf_line_count(0) > 10, "cheatsheet should have content")
    vim.cmd("bwipeout!")
  end)

  H.it("File › New File opens an empty unnamed buffer", function()
    scratch_buf({ "dirty" })
    vim.bo.modified = false
    activate(find("File", "New File"))
    H.eq("", vim.api.nvim_buf_get_name(0), "new buffer should be unnamed")
    H.eq({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  H.it("Edit › Select All selects every line", function()
    scratch_buf({ "one", "two", "three", "four" })
    activate(find("Edit", "Select All"))
    -- leaving visual mode writes the '< and '> marks
    vim.cmd("normal! \27")
    H.eq(1, vim.fn.line("'<"), "selection should start at line 1")
    H.eq(4, vim.fn.line("'>"), "selection should end at the last line")
  end)

  H.it("Edit › Undo and Redo move through the change list", function()
    scratch_buf({ "original" })
    -- Both set_lines calls otherwise land in one undo block, so a single :undo
    -- would jump back past "original" to the empty buffer. `:let &ul = &ul` is
    -- the standard way to close the current undo block.
    vim.cmd("let &l:undolevels = &l:undolevels")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
    activate(find("Edit", "Undo"))
    H.eq({ "original" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "undo should restore the original")
    activate(find("Edit", "Redo"))
    H.eq({ "edited" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "redo should reapply the edit")
  end)

  H.it("Edit › Copy Whole File yanks the buffer to the clipboard register", function()
    if vim.fn.has("clipboard") == 0 then
      H.skip("no clipboard provider in this environment")
    end
    scratch_buf({ "copy", "me" })
    activate(find("Edit", "Copy Whole File"))
    H.matches("copy", vim.fn.getreg("+"), "+ register should hold the buffer")
  end)

  H.it("File › Save writes the buffer to disk", function()
    local path = H.tmpdir("save") .. "/saved.txt"
    vim.cmd("enew!")
    vim.cmd("file " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "persisted" })
    activate(find("File", "Save"))
    H.ok(H.exists(path), "file should exist after Save")
    H.eq("persisted", H.read(path))
    vim.cmd("bwipeout!")
  end)

  H.it("View › Project Tree opens a neo-tree window", function()
    local dir = H.git_repo("treeview")
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local function tree_wins()
      local n = 0
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then n = n + 1 end
      end
      return n
    end
    H.eq(0, tree_wins(), "no tree before the entry runs")
    only_window()
    activate(find("View", "Project Tree"))
    H.wait(5000, function() return tree_wins() > 0 end, "a neo-tree window to appear")
    H.eq(1, tree_wins())
    activate(find("View", "Project Tree")) -- it is a toggle
    H.wait(5000, function() return tree_wins() == 0 end, "the tree to close again")
  end)

  H.it("Code › Problems opens the Trouble window when there is a diagnostic", function()
    -- Trouble declines to open with an empty list ("No results for
    -- **diagnostics**"), which is correct, so the buffer needs a real
    -- diagnostic before the entry has anything to show.
    -- A real file on disk, not an `enew` scratch: Trouble's diagnostics view
    -- filters out unnamed buffers, so a diagnostic on one is never shown.
    local path = H.tmpdir("diag") .. "/broken.txt"
    H.write(path, "broken line")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    only_window() -- drop the neo-tree window the explorer autocmd just opened
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("kebab_test_diag")
    vim.diagnostic.set(ns, buf, {
      {
        lnum = 0, col = 0, end_lnum = 0, end_col = 6,
        severity = vim.diagnostic.severity.ERROR,
        message = "deliberate test diagnostic",
        source = "kebab-test",
      },
    })
    H.eq(1, #vim.diagnostic.get(buf), "the diagnostic should be registered")

    local function trouble_wins()
      local n = 0
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "trouble" then n = n + 1 end
      end
      return n
    end

    activate(find("Code", "Problems"))
    H.wait(8000, function() return trouble_wins() > 0 end, "a trouble window to appear")

    activate(find("Code", "Problems")) -- toggles back off
    H.wait(8000, function() return trouble_wins() == 0 end, "the trouble window to close")

    vim.diagnostic.reset(ns, buf)
    vim.cmd("bwipeout!")
  end)

  H.it("Code › File Structure opens Aerial without a file ever having been opened", function()
    -- aerial is event = "LazyFile" upstream; before the cmd triggers were added
    -- this entry failed with E492 when reached from the dashboard.
    local notes = H.capture_notify(function()
      activate(find("Code", "File Structure"))
      H.drain(300)
    end)
    for _, n in ipairs(notes) do
      H.falsy(n.msg:match("not an editor command") or n.msg:match("E492"),
        "should not report a missing command: " .. n.msg)
      H.falsy(n.msg:match("is not available"), "should not report unavailable: " .. n.msg)
    end
  end)

  H.it("Run › Flutter › Pub Get resolves to a live command outside a Dart buffer", function()
    -- flutter-tools is ft = "dart"; the whole Flutter submenu used to be dead
    -- in every other buffer. Assert the command exists rather than running it,
    -- since running it would shell out to the Flutter SDK.
    scratch_buf({ "not dart" })
    local d = A.describe(find("Run", "Pub Get", "Flutter").cmd)
    H.eq("ex", d.kind)
    H.ok(vim.fn.exists(":" .. d.command) >= 1, ":" .. d.command .. " should be defined")
  end)

  H.it("Run › test entries dispatch to jdtls in Java and neotest elsewhere", function()
    -- neotest has no Java adapter here, so a Java buffer must reach jdtls.dap.
    -- Asserting on the dispatch target rather than running a test suite.
    local entry = find("Run", "Run Test at Cursor")
    local d = A.describe(entry.cmd)
    H.eq("custom", d.kind)
    H.ok(d.check(), "both test backends should resolve")

    scratch_buf({ "class X {}" })
    vim.bo.filetype = "java"
    local notes = H.capture_notify(function()
      activate(entry)
      H.drain(200)
    end)
    -- jdtls is not attached to a scratch buffer, so this must fail *through
    -- jdtls*, never by reporting neotest's "no tests found".
    for _, n in ipairs(notes) do
      H.falsy(n.msg:lower():match("no tests found"),
        "a Java buffer must not be routed to neotest: " .. n.msg)
    end
  end)
end)
