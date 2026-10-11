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
local BUFFER_LOCAL = {
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
        rows[#rows + 1] = { label = prefix .. e.name, rtxt = e.rtxt }
      end
    end
  end
end
for _, m in ipairs(menus) do
  walk(m.items, m.name .. " › ")
end

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
