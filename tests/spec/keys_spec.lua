-- Shortcuts as the keys a person presses.
--
-- "<leader>DD" was on screen in every right-click menu and 129 times in the
-- cheatsheet. It means nothing to anyone who has not read Neovim's
-- documentation, and it was asked for directly: "do not use leader or any
-- other stuff which you only understand".
local H = ...

local K = require("kebab.keys")

H.describe("rendering a shortcut", function()
  H.it("tells a sequence from a combination", function()
    -- The distinction, in the user's words: "it means first press --> second
    -- press --> third press OR first press + second press". An arrow is in
    -- order, a plus is together, and nothing else may join two keys.
    local saved = vim.g.mapleader
    vim.g.mapleader = " "
    H.eq("Space → D → D", K.human("<leader>DD"), "pressed one after the other")
    H.eq("Ctrl+Enter", K.human("<C-CR>"), "held together")
    H.eq("Space → Ctrl+r", K.human("<leader><C-r>"), "both at once: in order, the second held")
    vim.g.mapleader = saved
  end)

  H.it("names the leader key", function()
    local saved = vim.g.mapleader
    vim.g.mapleader = " "
    H.eq("Space → D → D", K.human("<leader>DD"))
    H.eq("Space → c → a", K.human("<leader>ca"))
    vim.g.mapleader = ","
    H.eq(", → g → g", K.human("<leader>gg"), "whatever the leader is, it is named")
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
    H.eq("Space → Space", K.human("<leader><space>"))
    H.eq("double click", K.human("<2-LeftMouse>"))
    H.eq("right click", K.human("<RightMouse>"))
  end)

  H.it("separates a sequence, so it reads as keystrokes", function()
    H.eq("] → p", K.human("]p"))
    H.eq("g → d", K.human("gd"))
    H.eq("Space → f → S", K.human("<leader>fS"), "a capital stays a capital: the legend says it means Shift")
  end)

  H.it("leaves a command alone", function()
    H.eq(":IdeDbRun", K.human(":IdeDbRun"))
    H.eq(":wa", K.human(":wa"))
  end)

  H.it("leaves anything with a space in it alone", function()
    -- A key specification never contains a literal space: the spacebar is
    -- `<space>`. So a string that does is prose or a shell command, and
    -- treating it as keystrokes spells it out one letter at a time. A pass
    -- over the cheatsheet did that and shipped `k e b a b   d b   name`.
    H.eq("kebab db name", K.human("kebab db name"))
    H.eq("kebab new x --type spring", K.human("kebab new x --type spring"))
    H.eq("bundle add sinatra", K.human("bundle add sinatra"))
  end)

  H.it("is unbothered by nonsense", function()
    H.eq("", K.human(""))
    H.eq("", K.human(nil))
    H.eq("<", K.human("<"), "an unterminated bracket is not a crash")
  end)
end)

H.describe("the separator", function()
  H.it("can be swapped for ASCII", function()
    local saved = vim.g.kebab_key_arrow
    vim.g.kebab_key_arrow = "->"
    local was = vim.g.mapleader
    vim.g.mapleader = " "
    H.eq("Space -> D -> D", K.human("<leader>DD"), "a terminal without the glyph can say ->")
    vim.g.mapleader = was
    vim.g.kebab_key_arrow = saved
    H.eq("→", K.arrow(), "cleared, it is the arrow again")
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
    H.eq({}, bad, "write what the user presses, e.g. `Space → D → D`")
  end)

  H.it("spells nothing out letter by letter", function()
    -- Two bugs with one shape: a key sequence written with plain spaces
    -- (which now has to be arrows) and text that was run through the
    -- renderer and came back as single characters. Three single-character
    -- words in a row is either one or the other.
    local bad = {}
    local fence = false
    for n, line in ipairs(vim.fn.readfile(path)) do
      if line:sub(1, 3) == "```" then
        fence = not fence
      elseif not fence then
        for token in line:gmatch("`([^`]+)`") do
          local run = 0
          for word in (token .. " "):gmatch("(%S*)%s") do
            run = (#word == 1) and run + 1 or 0
            if run >= 3 then
              bad[#bad + 1] = ("%d: %s"):format(n, token)
              break
            end
          end
        end
      end
    end
    H.eq({}, bad, "join keys with an arrow; do not space out words")
  end)

  H.it("says how to read a shortcut", function()
    local text = table.concat(vim.fn.readfile(path), "\n")
    H.matches("How to read these", text)
    H.matches("capital letter means hold Shift", text)
    H.matches("arrow means one key after the other", text, "the arrow has to be explained")
    H.matches("plus means\n?%s*hold them at the same time", text, "the plus has to be explained")
  end)
end)
