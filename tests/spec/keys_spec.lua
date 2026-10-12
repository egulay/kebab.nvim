-- Shortcuts as the keys a person presses.
--
-- "<leader>DD" was on screen in every right-click menu and 129 times in the
-- cheatsheet. It means nothing to anyone who has not read Neovim's
-- documentation, and it was asked for directly: "do not use leader or any
-- other stuff which you only understand".
local H = ...

local K = require("kebab.keys")

H.describe("rendering a shortcut", function()
  H.it("names the leader key", function()
    local saved = vim.g.mapleader
    vim.g.mapleader = " "
    H.eq("Space D D", K.human("<leader>DD"))
    H.eq("Space c a", K.human("<leader>ca"))
    vim.g.mapleader = ","
    H.eq(", g g", K.human("<leader>gg"), "whatever the leader is, it is named")
    vim.g.mapleader = saved
  end)

  H.it("names the modifiers", function()
    H.eq("Ctrl+Enter", K.human("<C-CR>"))
    H.eq("Alt+1", K.human("<A-1>"))
    H.eq("Shift+F6", K.human("<S-F6>"))
    H.eq("Ctrl+Shift+P", K.human("<C-S-P>"))
    H.eq("Ctrl+/", K.human("<C-/>"))
  end)

  H.it("names the keys that have names", function()
    H.eq("Esc", K.human("<Esc>"))
    H.eq("Tab", K.human("<Tab>"))
    H.eq("Space Space", K.human("<leader><space>"))
    H.eq("double click", K.human("<2-LeftMouse>"))
    H.eq("right click", K.human("<RightMouse>"))
  end)

  H.it("separates a sequence, so it reads as keystrokes", function()
    H.eq("] p", K.human("]p"))
    H.eq("g d", K.human("gd"))
    H.eq("Space f S", K.human("<leader>fS"), "a capital stays a capital: the legend says it means Shift")
  end)

  H.it("leaves a command alone", function()
    H.eq(":IdeDbRun", K.human(":IdeDbRun"))
    H.eq(":wa", K.human(":wa"))
  end)

  H.it("is unbothered by nonsense", function()
    H.eq("", K.human(""))
    H.eq("", K.human(nil))
    H.eq("<", K.human("<"), "an unterminated bracket is not a crash")
  end)
end)

H.describe("the cheatsheet", function()
  local path = _G.KEBAB_TEST.root .. "/CHEATSHEET.md"

  H.it("exists and is what :IdeCheatsheet opens", function()
    H.ok(H.exists(path))
  end)

  H.it("shows no key specification jargon", function()
    -- `<leader>`, `<C-x>`, `<CR>`: all of it is documentation shorthand, and
    -- this file is read on screen.
    local bad = {}
    for n, line in ipairs(vim.fn.readfile(path)) do
      for token in line:gmatch("`([^`]+)`") do
        if token:lower():find("leader") then
          bad[#bad + 1] = ("%d: %s"):format(n, token)
        elseif token:find("^<.*>$") and not token:find("^<[a-z]+>$") then
          bad[#bad + 1] = ("%d: %s"):format(n, token)
        end
      end
    end
    H.eq({}, bad, "write what the user presses, e.g. `Space D D`")
  end)

  H.it("says how to read a shortcut", function()
    local text = table.concat(vim.fn.readfile(path), "\n")
    H.matches("How to read these", text)
    H.matches("capital letter means hold Shift", text)
  end)
end)
