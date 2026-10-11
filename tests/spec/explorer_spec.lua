-- The always-on project tree.
--
-- This had no direct tests, and it is where a headline behaviour broke: the
-- layer declares `init` on the neo-tree spec, lazy.nvim *replaces* init rather
-- than chaining it, so LazyVim's own directory-argument autocmd was never
-- created and `nvim ~/Projects/thing` opened one plain window with no tree.
local H = ...
local E = require("kebab.explorer")

---Run `fn` with `dir` as the first argument in the arglist.
local function with_arg(path, fn)
  local saved = vim.fn.argv()
  pcall(vim.cmd, "silent! %argdelete")
  vim.cmd("argadd " .. vim.fn.fnameescape(path))
  local ok, err = pcall(fn)
  pcall(vim.cmd, "silent! %argdelete")
  for _, a in ipairs(saved) do
    pcall(vim.cmd, "argadd " .. vim.fn.fnameescape(a))
  end
  if not ok then
    error(err, 0)
  end
end

H.describe("the directory Neovim was started on", function()
  H.it("is recognised, because a directory produces no BufReadPost", function()
    local dir = H.tmpdir("explorer-dir")
    with_arg(dir, function()
      H.eq(dir:gsub("/+$", ""), E.directory_argument())
    end)
  end)

  H.it("is nil for a file argument", function()
    local dir = H.tmpdir("explorer-file")
    H.write(dir .. "/a.txt", "x")
    with_arg(dir .. "/a.txt", function()
      H.eq(nil, E.directory_argument())
    end)
  end)

  H.it("is nil for a path that does not exist", function()
    with_arg("/nonexistent-kebab-dir-xyz", function()
      H.eq(nil, E.directory_argument())
    end)
  end)

  H.it("is nil when there are no arguments", function()
    local saved = vim.fn.argv()
    pcall(vim.cmd, "silent! %argdelete")
    local got = E.directory_argument()
    for _, a in ipairs(saved) do
      pcall(vim.cmd, "argadd " .. vim.fn.fnameescape(a))
    end
    H.eq(nil, got)
  end)

  H.it("resolves a relative directory to a full path", function()
    local dir = H.tmpdir("explorer-rel")
    vim.fn.mkdir(dir .. "/sub", "p")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    with_arg("sub", function()
      H.eq(vim.fn.resolve(dir .. "/sub"), vim.fn.resolve(E.directory_argument() or ""))
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
  end)

  H.it("strips a trailing slash, so `nvim dir/` is the same as `nvim dir`", function()
    local dir = H.tmpdir("explorer-slash")
    with_arg(dir .. "/", function()
      H.eq(dir:gsub("/+$", ""), E.directory_argument())
    end)
  end)
end)

H.describe("the explorer's autocmds", function()
  H.it("covers a file argument and a directory argument", function()
    E.setup()
    local aus = vim.api.nvim_get_autocmds({ group = "ide_auto_explorer" })
    local events = {}
    for _, a in ipairs(aus) do
      events[a.event] = true
    end
    H.ok(events["BufReadPost"], "a file argument arrives as BufReadPost")
    H.ok(
      events["BufEnter"] or events["VimEnter"],
      "a directory argument needs its own trigger: " .. vim.inspect(vim.tbl_keys(events))
    )
  end)

  H.it("is registered from the neo-tree spec's init", function()
    -- init runs during lazy setup, before Neovim reads the file arguments, so
    -- the first BufReadPost is not missed
    local spec = dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/ui.lua")
    local neotree
    for _, entry in ipairs(spec) do
      if entry[1] == "nvim-neo-tree/neo-tree.nvim" then
        neotree = entry
      end
    end
    H.ok(neotree, "the neo-tree fragment should be there")
    H.eq("function", type(neotree.init))
  end)
end)
