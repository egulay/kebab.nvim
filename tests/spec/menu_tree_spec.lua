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
  H.it("loads without neo-tree having been required first", function()
    -- A file-scope require("neo-tree.sources.manager") used to make this module
    -- unloadable before lazy had started the plugin. CLAUDE.md lists that trap.
    package.loaded["kebab.menus.tree"] = nil
    local ok, fresh = pcall(require, "kebab.menus.tree")
    H.ok(ok, "module should load: " .. tostring(fresh))
    H.ok(#fresh >= 20, "should still define its entries")
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
    gr = "git_revert_file",
    gc = "git_commit",
    gp = "git_push",
    gl = "git_pull",
  }
  for key, command in pairs(expected) do
    H.it(("%s is bound to %s"):format(key, command), function()
      H.eq(command, mappings[key], ("tree mapping %q"):format(key))
    end)
  end

  H.it("single left click expands a folder but never opens a file", function()
    -- The mouse half of the brief: a stray click in the tree must not open a
    -- buffer, so <LeftRelease> only ever toggles directories.
    local handler = mappings["<LeftRelease>"]
    H.ok(A.callable(handler), "<LeftRelease> should be mapped to a function")
  end)

  H.it("the menu's git shortcuts all exist as tree mappings", function()
    -- rtxt is what the menu prints next to each entry; anything it claims for
    -- the git submenu should really be bound in the tree.
    local by_key = {}
    for _, leaf in ipairs(flat.leaves) do
      if leaf.label:match("^Git › ") and leaf.entry.rtxt and leaf.entry.rtxt:match("^g%l$") then
        by_key[leaf.entry.rtxt] = leaf.label
      end
    end
    H.ok(vim.tbl_count(by_key) >= 6, "expected the git submenu to advertise g-keys")
    for key, label in pairs(by_key) do
      H.ok(mappings[key] ~= nil, ("%s advertises %q, which is not mapped in the tree"):format(label, key))
    end
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
