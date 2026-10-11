-- Sweep of the project-tree right-click menu.
--
-- Same contract as menu_editor_spec: every leaf entry's target must resolve
-- now. The `call(...)` entries dispatch to a neo-tree command by name, so the
-- check is that neo-tree still has a command by that name -- a rename upstream
-- would otherwise only show up as a "no command 'x'" notification on click.
local H = ...
local A = require("kebab.menus.action")

-- The menu is only ever required from inside a neo-tree window, so the plugin
-- is loaded by then. Here it has to be loaded on purpose.
require("lazy").load({ plugins = { "neo-tree.nvim" } })

local menu = require("kebab.menus.tree")

local function walk(items, prefix, out)
  for i, entry in ipairs(items) do
    if entry.name == "separator" then
      out.separators = out.separators + 1
    elseif entry.items then
      H.ok(type(entry.name) == "string" and entry.name ~= "", ("[%d] submenu needs a name"):format(i))
      walk(entry.items, (prefix == "" and "" or prefix .. " › ") .. entry.name, out)
    else
      out.leaves[#out.leaves + 1] = {
        label = (prefix == "" and "" or prefix .. " › ") .. tostring(entry.name),
        entry = entry,
      }
    end
  end
  return out
end

local function validate(entry)
  local cmd = entry.cmd
  if type(cmd) == "string" then
    local ok, err = pcall(vim.api.nvim_parse_cmd, cmd, {})
    return ok, not ok and ("not a valid Ex command: " .. tostring(err):gsub("\n", " ")) or nil
  end
  if not A.callable(cmd) then
    return false, "cmd is a " .. type(cmd)
  end
  local d = A.describe(cmd)
  if not d then
    return false, "opaque closure -- build it with kebab.menus.action"
  end

  if d.kind == "neotree" then
    local own, common = menu.source_commands("filesystem")
    local fn = own[d.command] or common[d.command]
    if fn == nil then
      return false, ("neo-tree has no command %q"):format(d.command)
    end
    if not A.callable(fn) then
      return false, ("neo-tree command %q is a %s"):format(d.command, type(fn))
    end
    return true
  elseif d.kind == "ex" then
    local ok, err = pcall(vim.api.nvim_parse_cmd, d.cmdline, {})
    return ok, not ok and ((":%s is not available (%s)"):format(d.command, tostring(err):gsub("\n", " "))) or nil
  elseif d.kind == "global" then
    if _G[d.global] == nil then
      return false, d.global .. " global is not set"
    end
    local target, missing = A.resolve(_G[d.global], d.path)
    if not target or not A.callable(target) then
      return false, ("%s.%s missing (no .%s)"):format(d.global, d.path, tostring(missing))
    end
    return true
  elseif d.kind == "custom" then
    local ok, res, reason = pcall(d.check)
    if not ok then
      return false, "check() errored: " .. tostring(res)
    end
    return res, not res and tostring(reason) or nil
  end
  return false, "unknown action kind " .. tostring(d.kind)
end

local flat = walk(menu, "", { leaves = {}, separators = 0 })

H.describe("tree menu", function()
  -- A file-scope require("neo-tree.sources.manager") used to make this module
  -- unloadable before lazy had started the plugin. CLAUDE.md lists that trap.
  --
  -- This has to run in a *fresh process*. Clearing package.loaded and requiring
  -- again proved nothing: this spec loads neo-tree at file scope, and
  -- menu_behaviour_spec loads it earlier in the run, so by the time the test
  -- ran neo-tree was on the runtimepath and the require would have succeeded
  -- even with the trap reintroduced.
  H.it("loads in a session where neo-tree has never been loaded", function()
    local root = _G.KEBAB_TEST.root
    local probe = table.concat({
      'local ok, m = pcall(require, "kebab.menus.tree")',
      'local n = (type(m) == "table") and #m or 0',
      'io.write(("ok=%s entries=%d neotree=%s\\n"):format(tostring(ok), n,',
      '  tostring(package.loaded["neo-tree"] ~= nil or package.loaded["neo-tree.sources.manager"] ~= nil)))',
      'if not ok then io.write(tostring(m) .. "\\n") end',
      'vim.cmd("qa!")',
    }, "\n")
    local res = vim.system({
      vim.v.progpath,
      "-n",
      "--headless",
      "-u",
      "NONE",
      "--cmd",
      "set runtimepath+=" .. root,
      "-c",
      "lua " .. probe,
    }, { text = true }):wait(60000)
    local out = (res.stdout or "") .. (res.stderr or "")
    H.matches("ok=true", out, "the module must load with no neo-tree: " .. out)
    H.matches("entries=2%d", out, "and still define its entries: " .. out)
    H.matches("neotree=false", out, "neo-tree must really not be loaded: " .. out)
  end)

  H.it("found the expected entries", function()
    H.ok(#flat.leaves >= 20, "expected 20+ leaf entries, got " .. #flat.leaves)
  end)

  H.it("has no duplicate entry paths", function()
    local seen = {}
    for _, leaf in ipairs(flat.leaves) do
      H.falsy(seen[leaf.label], "duplicate entry: " .. leaf.label)
      seen[leaf.label] = true
    end
  end)

  H.it("rejects a neo-tree command that does not exist", function()
    local bogus = A.tag(function() end, { kind = "neotree", command = "no_such_command_zzz" })
    local ok, reason = validate({ name = "x", cmd = bogus })
    H.falsy(ok)
    H.matches("no command", reason)
  end)
end)

H.describe("tree menu entries", function()
  for _, leaf in ipairs(flat.leaves) do
    H.it(leaf.label, function()
      H.ok(type(leaf.entry.name) == "string" and leaf.entry.name ~= "", "entry needs a name")
      H.ok(leaf.entry.cmd ~= nil, "entry has no cmd")
      local ok, reason = validate(leaf.entry)
      H.ok(ok, reason)
    end)
  end
end)

-- The keys advertised in `rtxt` are what neo-tree's window mappings bind. A
-- menu that prints the wrong shortcut is a small lie that erodes trust in the
-- rest of it, so the mappings this layer contributes are checked against the
-- options lazy.nvim actually hands to neo-tree.setup(). Reading them from
-- `require("neo-tree").config` does not work -- neo-tree does not publish its
-- resolved config there -- and this source additionally proves the layer's
-- opts survive LazyVim's own neo-tree extra rather than being overwritten.
local function neotree_opts()
  local spec = require("lazy.core.config").plugins["neo-tree.nvim"]
  H.ok(spec, "neo-tree.nvim should be a known plugin")
  return require("lazy.core.plugin").values(spec, "opts", false)
end

H.describe("tree mappings", function()
  local mappings = vim.tbl_get(neotree_opts(), "window", "mappings") or {}

  local expected = {
    ga = "git_add_file",
    gu = "git_unstage_file",
    gt = "git_toggle_file_stage",
    gc = "git_commit",
    gp = "git_push",
    gl = "git_pull",
    gA = "git_add_all",
    gU = "git_undo_last_commit",
  }
  for key, command in pairs(expected) do
    H.it(("%s is bound to %s"):format(key, command), function()
      H.eq(command, mappings[key], ("tree mapping %q"):format(key))
    end)
  end

  -- gr is deliberately NOT neo-tree's git_revert_file: that is a plain
  -- `git checkout HEAD -- <path>`, which ignores untracked files -- the exact
  -- bug kebab.git's hand-written revert exists to fix. The menu advertises gr
  -- for "Revert / Discard Changes", so gr has to be that.
  for _, key in ipairs({ "gr", "gy", "gY" }) do
    H.it(("%s runs one of this layer's own actions"):format(key), function()
      H.ok(A.callable(mappings[key]), ("tree mapping %q should be a function"):format(key))
    end)
  end

  H.it("gr is this layer's revert, not neo-tree's", function()
    H.falsy(mappings["gr"] == "git_revert_file", "git_revert_file leaves untracked files behind")
    local actions = require("kebab.menus.tree").actions
    H.eq("function", type(actions.revert))
    H.eq("function", type(actions.copy_absolute_path))
    H.eq("function", type(actions.copy_relative_path))
  end)

  H.it("single left click expands a folder but never opens a file", function()
    -- The mouse half of the brief: a stray click in the tree must not open a
    -- buffer, so <LeftRelease> only ever toggles directories.
    local handler = mappings["<LeftRelease>"]
    H.ok(A.callable(handler), "<LeftRelease> should be mapped to a function")
  end)

  -- This used to filter rtxt to `^g%l$`, which is two lowercase characters
  -- beginning with g -- so it could not see `gU`, `gA`, `gy`, `gY` or `A`, and
  -- every one of those was wrong. The sweep now reads the keys a *live* tree
  -- buffer actually has, which also covers neo-tree's and LazyVim's own.
  H.it("every shortcut the tree menu prints is really bound in the tree", function()
    require("lazy").load({ plugins = { "neo-tree.nvim" } })
    local dir = H.tmpdir("menu-keys")
    H.write(dir .. "/a.txt", "x")
    local cmd = require("neo-tree.command")
    pcall(cmd.execute, { action = "show", dir = dir })
    H.wait(5000, function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then
          return true
        end
      end
      return false
    end, "a neo-tree window should open")

    local tree_buf
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(w)
      if vim.bo[buf].filetype == "neo-tree" then
        tree_buf = buf
      end
    end
    H.ok(tree_buf, "the tree buffer should be findable")

    local bound = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(tree_buf, "n")) do
      bound[m.lhs] = true
    end

    local missing = {}
    local checked = 0
    for _, leaf in ipairs(flat.leaves) do
      local rtxt = leaf.entry.rtxt
      -- <leader>… entries are global keymaps, covered by keymaps_spec
      if rtxt and rtxt ~= "" and not rtxt:match("^<leader>") then
        checked = checked + 1
        if not bound[rtxt] then
          missing[#missing + 1] = ("%s advertises %q"):format(leaf.label, rtxt)
        end
      end
    end
    H.ok(checked >= 20, "expected plenty of advertised keys, got " .. checked)
    H.eq({}, missing, "an advertised key that is not bound is worse than none")
    H.reset_editor()
  end)
end)

H.describe("tree filesystem behaviour", function()
  local opts = neotree_opts()

  H.it("shows dotfiles, because .env and .github matter", function()
    H.eq(false, vim.tbl_get(opts, "filesystem", "filtered_items", "hide_dotfiles"))
  end)

  H.it("still hides .git, node_modules and .DS_Store", function()
    local never = vim.tbl_get(opts, "filesystem", "filtered_items", "never_show") or {}
    for _, name in ipairs({ ".git", "node_modules", ".DS_Store" }) do
      H.ok(vim.tbl_contains(never, name), name .. " should be in never_show")
    end
  end)

  H.it("follows the file being edited, like a graphical project pane", function()
    H.eq(true, vim.tbl_get(opts, "filesystem", "follow_current_file", "enabled"))
  end)

  H.it("watches the filesystem so the tree does not go stale", function()
    H.eq(true, vim.tbl_get(opts, "filesystem", "use_libuv_file_watcher"))
  end)
end)

-- Two of neo-tree's nine default git markers are plain Unicode dingbats --
-- `added = "✚"` (U+271A) and `deleted = "✖"` (U+2716) -- and a Nerd Font does
-- not carry those. the monospace Nerd Font has every other symbol it uses and
-- neither of these, so a file an agent had just *added* rendered as a tofu box.
H.describe("the tree's glyphs", function()
  -- str2list, not utf8.codes: this is LuaJIT, which has no utf8 library.
  local function codepoints(str)
    return vim.fn.str2list(str)
  end

  ---Is this codepoint one a Nerd Font is expected to carry?
  ---
  ---ASCII, or the private-use areas Nerd Fonts patch into. A dingbat like
  ---U+271A is in neither, which is the whole bug.
  local function nerd_safe(cp)
    return cp < 0x2000
      or (cp >= 0xE000 and cp <= 0xF8FF)
      or (cp >= 0xF0000 and cp <= 0xFFFFD)
      or (cp >= 0x100000 and cp <= 0x10FFFD)
  end

  ---What this layer configures, merged over what neo-tree defaults to.
  ---
  ---Read from the live config when neo-tree has been set up in this session,
  ---and from the spec file plus neo-tree's own defaults otherwise -- so this
  ---asserts the same thing either way instead of skipping, which is what it
  ---did on roughly one run in two.
  local function git_symbols()
    pcall(function()
      require("lazy").load({ plugins = { "neo-tree.nvim" } })
    end)
    local live = vim.tbl_get(require("neo-tree").config or {}, "default_component_configs", "git_status", "symbols")
    if type(live) == "table" and not vim.tbl_isempty(live) then
      return live
    end
    local defaults = {}
    local ok, d = pcall(dofile, vim.fn.expand("~/.local/share/nvim/lazy/neo-tree.nvim/lua/neo-tree/defaults.lua"))
    if ok then
      defaults = vim.tbl_get(d or {}, "default_component_configs", "git_status", "symbols") or {}
    end
    local ours = {}
    for _, entry in ipairs(dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/ui.lua")) do
      if entry[1] == "nvim-neo-tree/neo-tree.nvim" then
        ours = vim.tbl_get(entry, "opts", "default_component_configs", "git_status", "symbols") or {}
      end
    end
    return vim.tbl_extend("force", defaults, ours)
  end

  H.it("uses no symbol outside a Nerd Font's ranges", function()
    local symbols = git_symbols()
    H.ok(not vim.tbl_isempty(symbols), "the symbols should be resolvable either way")
    local offenders = {}
    for name, glyph in pairs(symbols) do
      if type(glyph) == "string" and name ~= "align" then
        for _, cp in ipairs(codepoints(glyph)) do
          if not nerd_safe(cp) then
            offenders[#offenders + 1] = ("%s = %s (U+%X)"):format(name, glyph, cp)
          end
        end
      end
    end
    H.eq({}, offenders, "a dingbat renders as a box in a Nerd Font terminal")
  end)

  H.it("overrides exactly the two markers neo-tree gets wrong", function()
    local spec = dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/ui.lua")
    local symbols
    for _, entry in ipairs(spec) do
      if entry[1] == "nvim-neo-tree/neo-tree.nvim" then
        symbols = vim.tbl_get(entry, "opts", "default_component_configs", "git_status", "symbols")
      end
    end
    H.ok(symbols, "the layer should set git_status symbols")
    H.ok(symbols.added, "added is the one an agent creating files hits")
    H.ok(symbols.deleted, "deleted has the same problem")
    for name, glyph in pairs(symbols) do
      for _, cp in ipairs(codepoints(glyph)) do
        H.ok(nerd_safe(cp), ("%s = U+%X is outside a Nerd Font's ranges"):format(name, cp))
      end
    end
  end)

  -- The real check, when the tooling is there: ask the installed font.
  H.it("uses glyphs this machine's font actually has", function()
    if vim.fn.executable("fc-list") == 0 then
      H.skip("fc-list is needed to inspect the font")
    end
    local font = "the monospace Nerd Font"
    local probe = vim.system({ "fc-list", ":charset=F067", "family" }, { text = true }):wait(30000)
    if not (probe.stdout or ""):find(font, 1, true) then
      H.skip(font .. " is not installed on this machine")
    end
    local symbols = git_symbols()
    H.ok(not vim.tbl_isempty(symbols), "the symbols should be resolvable either way")
    local missing = {}
    for name, glyph in pairs(symbols) do
      if type(glyph) == "string" and name ~= "align" then
        for _, cp in ipairs(codepoints(glyph)) do
          if cp > 0x2000 then
            local res = vim.system({ "fc-list", (":charset=%X"):format(cp), "family" }, { text = true }):wait(30000)
            if not (res.stdout or ""):find(font, 1, true) then
              missing[#missing + 1] = ("%s = U+%X"):format(name, cp)
            end
          end
        end
      end
    end
    H.eq({}, missing, "these render as a box in the terminal")
  end)
end)
