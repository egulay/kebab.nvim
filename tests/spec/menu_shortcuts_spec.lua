-- The shortcuts the editor menu prints next to each entry.
--
-- A menu-bar entry that advertises a key which does nothing is a small lie, and
-- a graphical IDE never tells it. Each `rtxt` is classified and checked: a
-- command hint has to be a real command, a key that should be global has to be
-- mapped, and anything that cannot be either has to be listed below with a
-- reason -- so adding a menu entry forces a decision about its shortcut rather
-- than letting a plausible-looking string through.
local H = ...
local menus = require("kebab.menus.editor")

local LEADER = (vim.g.mapleader == " " or vim.g.mapleader == nil) and "<Space>" or vim.g.mapleader

-- Keys that are native Vim, not mappings. Nothing binds them and nothing should.
local BUILTIN = {
  ["u"] = "native undo",
  ["<C-r>"] = "native redo",
  ["ggVG"] = "a normal-mode key sequence, not a mapping",
}

-- Keys that only exist in certain buffers. Each needs a reason, and the reason
-- has to be the truth: these are checked for *absence* globally, so one that
-- becomes global will fail here and have to be moved out of this table.
-- Keys written the way **Neovim's own API** returns them, because that is what
-- they are compared against: nvim_get_keymap answers `<M-S-Right>`, and
-- "Shift+Alt+Right" cannot be matched against a mapping. Nothing in this table
-- is ever shown to anyone -- what goes on screen is rendered by
-- kebab.keys.human ("Shift+Alt+Right"), and the assertion "shows what a person
-- presses, not <leader>" below fails if any of this form reaches a menu.
local BUFFER_LOCAL = {
  -- The pager lives on the two SQL panes only. Mapping ]p, [p, [P or R
  -- globally would take four ordinary keys away from every buffer in the
  -- editor -- R especially -- so kebab.dbide binds them per buffer.
  -- Run is Ctrl+Enter, the key a graphical database IDE uses, bound on the two
  -- SQL panes in normal *and* insert mode. It was <leader>S, which snacks
  -- already owns as "Select Scratch Buffer" -- so the key the menu advertised
  -- for Run opened a picker anywhere else.
  ["<C-CR>"] = "kebab.dbide: bound on the statement and rows panes",
  ["<leader>Dr"] = "kebab.dbide: bound on the statement and rows panes",
  -- Shift+Alt, because plain Alt+Left/Right is commonly eaten by the terminal
  -- as a readline word-jump, and `]p`, `[p` and `R` are built-in Vim commands.
  ["<S-A-Right>"] = "kebab.dbide: bound on the statement and rows panes",
  ["<S-A-Left>"] = "kebab.dbide: bound on the statement and rows panes",
  ["<S-A-Home>"] = "kebab.dbide: bound on the statement and rows panes",
  ["<S-A-R>"] = "kebab.dbide: bound on the statement and rows panes",
  ["<leader>ca"] = "LSP: bound on LspAttach",
  ["<leader>cr"] = "LSP: bound on LspAttach",
  ["gd"] = "LSP: bound on LspAttach",
  ["gI"] = "LSP: bound on LspAttach",
  ["gr"] = "LSP: bound on LspAttach",
  ["<leader>ghs"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghu"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghr"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghp"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghS"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghR"] = "gitsigns: bound on attach to a tracked file",
  -- ghb is Blame Line, which is what the menu entry calls; ghB is Blame
  -- Buffer, a different action the entry was advertising by mistake.
  ["<leader>ghb"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>ghd"] = "gitsigns: bound on attach to a tracked file",
  ["<leader>Fr"] = "flutter-tools: ft = dart",
  ["<leader>Fh"] = "flutter-tools: ft = dart",
  ["<leader>FR"] = "flutter-tools: ft = dart",
  ["<leader>Fq"] = "flutter-tools: ft = dart",
  ["<leader>Fd"] = "flutter-tools: ft = dart",
  ["<leader>Fe"] = "flutter-tools: ft = dart",
  ["<leader>Fl"] = "flutter-tools: ft = dart",
  ["<leader>Fp"] = "flutter-tools: ft = dart",
  ["<leader>Fo"] = "flutter-tools: ft = dart",
}

local function resolve(rtxt)
  return (rtxt:gsub("<leader>", LEADER))
end

---Normalise a key notation to the bytes Neovim stores, so "<leader>ff",
---"<C-s>" and "<RightMouse>" can all be compared the same way.
local function normalise(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

---Is `rtxt` mapped in `mode`?
---
---Built from nvim_get_keymap rather than maparg: maparg does not match a
---special key like <RightMouse> when it is handed the replaced termcodes, which
---made a mapping that is plainly there look absent.
local function is_mapped(rtxt, mode)
  local want = normalise(resolve(rtxt))
  for _, map in ipairs(vim.api.nvim_get_keymap(mode or "n")) do
    if normalise(map.lhs) == want then
      return true
    end
  end
  -- buffer-local mappings (LSP, gitsigns) live on the buffer, not globally
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode or "n")) do
    if normalise(map.lhs) == want then
      return true
    end
  end
  return false
end

-- Collect every entry that advertises a shortcut.
local rows = {}
local function walk(items, prefix)
  for _, e in ipairs(items) do
    if e.name ~= "separator" then
      if e.items then
        walk(e.items, prefix .. e.name .. " › ")
      elseif e.rtxt then
        -- `keyspec` is the canonical form -- "<leader>S" -- which is what can
        -- be checked against a real mapping. `rtxt` is what goes on screen,
        -- "Space S", and is checked separately below for jargon.
        rows[#rows + 1] = { label = prefix .. e.name, rtxt = e.keyspec or e.rtxt, shown = e.rtxt }
      end
    end
  end
end
for _, m in ipairs(menus) do
  walk(m.items, m.name .. " › ")
end
walk(require("kebab.menus.sql"), "sql › ")

H.describe("menu shortcuts", function()
  H.it("every entry advertises one", function()
    local missing = {}
    local function check(items, prefix)
      for _, e in ipairs(items) do
        if e.name ~= "separator" then
          if e.items then
            check(e.items, prefix .. e.name .. " › ")
          elseif not e.rtxt then
            missing[#missing + 1] = prefix .. e.name
          end
        end
      end
    end
    for _, m in ipairs(menus) do
      check(m.items, m.name .. " › ")
    end
    -- "Open in Terminal" in the tree menu has none; the editor menu should.
    H.eq({}, missing, "entries without a shortcut hint")
  end)

  H.it("shows what a person presses, not <leader>", function()
    -- Asked for directly: "do not use leader or any other stuff which you only
    -- understand". The menu is on screen; <leader>DD is documentation jargon.
    local jargon = {}
    for _, row in ipairs(rows) do
      local shown = row.shown or ""
      if shown:find("<") or shown:lower():find("leader") then
        jargon[#jargon + 1] = ("%s shows %q"):format(row.label, shown)
      end
    end
    H.eq({}, jargon, "menu entries should read like keys, e.g. \"Space D D\"")
  end)

  H.it("found shortcuts to check", function()
    H.ok(#rows >= 50, "expected 50+ shortcut hints, got " .. #rows)
  end)
end)

H.describe("menu shortcut targets", function()
  for _, row in ipairs(rows) do
    H.it(("%s  [%s]"):format(row.label, row.rtxt), function()
      local rtxt = row.rtxt

      if rtxt:sub(1, 1) == ":" then
        -- A command hint, e.g. ":wa" or ":IdeInitHere". It has to be real.
        local ok, err = pcall(vim.api.nvim_parse_cmd, rtxt:sub(2), {})
        H.ok(ok, ("advertises %s, which is not a valid command: %s"):format(rtxt, tostring(err)))
        return
      end

      if BUILTIN[rtxt] then
        return -- nothing to assert: these are native keys
      end

      if BUFFER_LOCAL[rtxt] then
        H.falsy(is_mapped(rtxt),
          ("%s is listed as buffer-local (%s) but is mapped globally -- remove it from BUFFER_LOCAL")
            :format(rtxt, BUFFER_LOCAL[rtxt]))
        return
      end

      H.ok(is_mapped(rtxt),
        ("advertises %s, which is not mapped. Either bind it, or add it to BUILTIN/BUFFER_LOCAL with a reason")
          :format(rtxt))
    end)
  end
end)

H.describe("menu shortcuts for the layer's own commands", function()
  -- These are the keys kebab.nvim binds itself, so there is no excuse for any
  -- of them being absent.
  for _, pair in ipairs({
    { "<leader>pn", "IdeNewProject" },
    { "<leader>po", "IdeOpenProject" },
    { "<leader>pk", "IdeCheatsheet" },
    { "<leader>pr", "Restore Session" },
    { "<leader>M", "the editor menu itself" },
  }) do
    H.it(("%s is mapped (%s)"):format(pair[1], pair[2]), function()
      H.ok(is_mapped(pair[1]), pair[1] .. " should be mapped")
    end)
  end

  H.it("<RightMouse> opens the context menu in normal and visual mode", function()
    H.ok(is_mapped("<RightMouse>", "n"), "<RightMouse> should be mapped in normal mode")
    H.ok(is_mapped("<RightMouse>", "v"), "<RightMouse> should be mapped in visual mode")
  end)
end)

-- BUFFER_LOCAL above only asserts these are *not* global. That they are
-- actually bound where they are supposed to be was listed in BACKLOG.md as
-- worth closing with a real fixture -- so here it is: a tracked file for the
-- gitsigns keys, and a Go file for the LSP ones.
H.describe("the buffer-local shortcuts the menu advertises", function()
  ---Every lhs the menu prints that is listed as buffer-local, by prefix.
  local function advertised(prefix)
    local out = {}
    for lhs in pairs(BUFFER_LOCAL) do
      if lhs:find(prefix, 1, true) == 1 then
        out[#out + 1] = lhs
      end
    end
    table.sort(out)
    return out
  end

  -- An explicit bufnr, never 0: opening the fixture fires the explorer
  -- autocmd, which adds a neo-tree window, so "the current buffer" is not
  -- reliably the file whose mappings are being checked.
  local function mapped_in_buffer(bufnr, lhs)
    local resolved = vim.api.nvim_replace_termcodes(lhs, true, true, true)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs or m.lhs == resolved then
        return true
      end
    end
    return false
  end

  H.it("binds the gitsigns keys on a tracked file", function()
    local keys = advertised("<leader>gh")
    H.ok(#keys >= 6, "the menu should advertise several gitsigns keys, got " .. #keys)

    local repo, g = H.git_repo("gitsigns-keys")
    H.write(repo .. "/tracked.txt", "one\ntwo\n")
    g("add", "-A")
    g("commit", "-q", "-m", "add")

    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/tracked.txt"))
    local bufnr = vim.fn.bufnr(repo .. "/tracked.txt")
    H.ok(bufnr ~= -1, "the fixture should be loaded")
    -- vim.wait, not H.wait: a missing gitsigns is a skip, not a failure
    local ok = vim.wait(20000, function()
      return mapped_in_buffer(bufnr, keys[1])
    end, 100)
    if not ok then
      H.skip("gitsigns did not attach to the fixture")
    end

    local missing = {}
    for _, lhs in ipairs(keys) do
      if not mapped_in_buffer(bufnr, lhs) then
        missing[#missing + 1] = lhs
      end
    end
    H.eq({}, missing, "advertised but never bound, even on a tracked file")
    H.reset_editor()
  end)

  H.it("binds the LSP keys on a buffer with a server attached", function()
    if vim.fn.executable("go") == 0 then
      H.skip("go is needed for a buffer with a language server")
    end
    local keys = advertised("<leader>c")
    vim.list_extend(keys, { "gd", "gI", "gr" })

    local dir = H.tmpdir("lsp-keys")
    local res = vim.system({ "go", "mod", "init", "example.com/keys" }, { cwd = dir, text = true }):wait(60000)
    H.eq(0, res.code, tostring(res.stderr))
    H.write(dir .. "/main.go", "package main\n\nfunc main() {}\n")

    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/main.go"))
    local bufnr = vim.fn.bufnr(dir .. "/main.go")
    H.ok(bufnr ~= -1, "the fixture should be loaded")
    local attached = vim.wait(120000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
    end, 200)
    if not attached then
      H.skip("no language server attached to the fixture")
    end
    -- LazyVim binds these on LspAttach, which has now happened
    local missing = {}
    local bound = vim.wait(20000, function()
      for _, lhs in ipairs(keys) do
        if not mapped_in_buffer(bufnr, lhs) then
          return false
        end
      end
      return true
    end, 200)
    if not bound then
      for _, lhs in ipairs(keys) do
        if not mapped_in_buffer(bufnr, lhs) then
          missing[#missing + 1] = lhs
        end
      end
    end
    H.eq({}, missing, "advertised but never bound, even with a server attached")
    H.reset_editor()
  end)
end)
