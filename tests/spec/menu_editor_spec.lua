-- The editor-menu sweep BACKLOG.md asks for.
--
-- Every leaf entry gets its own assertion, so a failure names the entry rather
-- than "the menu is broken". What is checked is that the entry's target exists
-- *now*, in a fully loaded Neovim -- which is the failure mode these entries
-- actually have: a command that belongs to a lazy-loaded plugin, a module
-- function that moved, a path that never existed.
local H = ...
local A = require("kebab.menus.action")

-- Flatten the menu tree into leaf entries, remembering where each one lives.
local function walk(items, prefix, out)
  for i, entry in ipairs(items) do
    local where = ("%s[%d]"):format(prefix, i)
    if entry.name == "separator" then
      out.separators = out.separators + 1
    elseif entry.items then
      H.ok(type(entry.name) == "string" and entry.name ~= "", where .. " submenu needs a name")
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

---Can this entry's target be reached right now? Returns ok, reason.
local function validate(entry)
  local cmd = entry.cmd

  if type(cmd) == "string" then
    -- Ask Neovim itself; it normalises abbreviations and rejects anything that
    -- is not a real command, which is exactly the question being asked.
    local ok, err = pcall(vim.api.nvim_parse_cmd, cmd, {})
    if not ok then
      return false, "not a valid Ex command: " .. tostring(err):gsub("\n", " ")
    end
    return true
  end

  if not A.callable(cmd) then
    return false, "cmd is a " .. type(cmd) .. ", expected a string or an action"
  end

  local d = A.describe(cmd)
  if not d then
    -- An opaque closure. This is the hole kebab.menus.action exists to close:
    -- a pcall inside such a closure swallows a broken target silently.
    return false, "opaque closure -- build it with kebab.menus.action so it can be checked"
  end

  if d.kind == "ex" then
    local ok, err = pcall(vim.api.nvim_parse_cmd, d.cmdline, {})
    if not ok then
      return false, (":%s is not available (%s)"):format(d.command, tostring(err):gsub("\n", " "))
    end
    return true
  elseif d.kind == "mod" then
    local ok, mod = pcall(require, d.module)
    if not ok then
      return false, "require('" .. d.module .. "') failed"
    end
    local target, missing = A.resolve(mod, d.path)
    if not target then
      return false, ("%s.%s missing (no .%s)"):format(d.module, d.path, tostring(missing))
    end
    if not A.callable(target) then
      return false, ("%s.%s is a %s, not callable"):format(d.module, d.path, type(target))
    end
    return true
  elseif d.kind == "global" then
    if _G[d.global] == nil then
      return false, d.global .. " global is not set"
    end
    local target, missing = A.resolve(_G[d.global], d.path)
    if not target then
      return false, ("%s.%s missing (no .%s)"):format(d.global, d.path, tostring(missing))
    end
    if not A.callable(target) then
      return false, ("%s.%s is a %s, not callable"):format(d.global, d.path, type(target))
    end
    return true
  elseif d.kind == "pick" then
    if _G.LazyVim == nil then
      return false, "LazyVim global is not set"
    end
    if not A.callable(_G.LazyVim.pick) then
      return false, "LazyVim.pick is not callable"
    end
    local ok, opener = pcall(_G.LazyVim.pick, d.source, d.opts)
    if not ok then
      return false, ("LazyVim.pick(%q) errored: %s"):format(d.source, tostring(opener))
    end
    if not A.callable(opener) then
      return false, ("LazyVim.pick(%q) returned %s, not a function"):format(d.source, type(opener))
    end
    return true
  elseif d.kind == "lsp" then
    local target, missing = A.resolve(vim.lsp.buf, d.path)
    if not target or not A.callable(target) then
      return false, "vim.lsp.buf." .. d.path .. " missing (no ." .. tostring(missing) .. ")"
    end
    return true
  elseif d.kind == "custom" then
    local ok, res, reason = pcall(d.check)
    if not ok then
      return false, "check() errored: " .. tostring(res)
    end
    if not res then
      return false, "check() failed: " .. tostring(reason)
    end
    return true
  end

  return false, "unknown action kind " .. tostring(d.kind)
end

local menus = require("kebab.menus.editor")
local flat = { leaves = {}, separators = 0 }
for _, m in ipairs(menus) do
  walk(m.items, m.name, flat)
end

-- The SQL menu too, or its own entries -- Run Statement and the pager, the
-- ones added because they were missing -- would be the only menu in the layer
-- nothing checks. It is a flat list with leaves at the top level, so it is
-- walked directly rather than per section.
walk(require("kebab.menus.sql"), "sql", flat)
walk(require("kebab.menus.dbtree"), "dbtree", flat)

H.describe("editor menu", function()
  H.it("has the expected top-level menus", function()
    local names = vim.tbl_map(function(m) return m.name end, menus)
    H.eq({ "Project", "File", "Edit", "Code", "Run", "Git", "Database", "View" }, names)
  end)

  H.it("every top-level menu has items", function()
    for _, m in ipairs(menus) do
      H.ok(type(m.items) == "table" and #m.items > 0, m.name .. " should have items")
    end
  end)

  H.it("found a plausible number of entries to check", function()
    H.ok(#flat.leaves >= 60, "expected 60+ leaf entries, got " .. #flat.leaves)
  end)

  H.it("has no duplicate entry paths", function()
    local seen = {}
    for _, leaf in ipairs(flat.leaves) do
      H.falsy(seen[leaf.label], "duplicate entry: " .. leaf.label)
      seen[leaf.label] = true
    end
  end)
end)

-- A validator that cannot fail is worthless, so prove it rejects each way an
-- entry can be broken before trusting the 70-odd passes below.
H.describe("the sweep itself", function()
  H.it("rejects an Ex command that does not exist", function()
    local ok, reason = validate({ name = "x", cmd = "NoSuchCommandZZZ" })
    H.falsy(ok, "should have been rejected")
    H.matches("not a valid Ex command", reason)
  end)

  H.it("rejects an action pointing at a missing module", function()
    local ok, reason = validate({ name = "x", cmd = A.mod("no.such.module.zzz", "go") })
    H.falsy(ok)
    H.matches("failed", reason)
  end)

  H.it("rejects an action pointing at a missing function in a real module", function()
    local ok, reason = validate({ name = "x", cmd = A.mod("gitsigns", "no_such_function_zzz") })
    H.falsy(ok)
    H.matches("missing", reason)
  end)

  H.it("rejects a missing path on a real global", function()
    local ok, reason = validate({ name = "x", cmd = A.g("Snacks", "picker.no_such_zzz") })
    H.falsy(ok)
    H.matches("missing", reason)
  end)

  H.it("rejects an opaque closure", function()
    local ok, reason = validate({ name = "x", cmd = function() end })
    H.falsy(ok)
    H.matches("opaque closure", reason)
  end)

  H.it("rejects a custom action whose check fails", function()
    local bad = A.custom("bad", function() end, function() return false, "nope" end)
    local ok, reason = validate({ name = "x", cmd = bad })
    H.falsy(ok)
    H.matches("nope", reason)
  end)

  H.it("accepts a real command and a real module function", function()
    H.ok(validate({ name = "x", cmd = "write" }))
    H.ok(validate({ name = "x", cmd = A.mod("gitsigns", "stage_hunk") }))
  end)
end)

H.describe("editor menu entries", function()
  for _, leaf in ipairs(flat.leaves) do
    H.it(leaf.label, function()
      H.ok(type(leaf.entry.name) == "string" and leaf.entry.name ~= "", "entry needs a name")
      H.ok(leaf.entry.cmd ~= nil, "entry has no cmd")
      local ok, reason = validate(leaf.entry)
      H.ok(ok, reason)
    end)
  end
end)
