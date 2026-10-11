-- The layer must not quietly take a key LazyVim already documents.
--
-- This exists because it did: `<leader>fn` ("New File") was overridden by the
-- template picker, which silently broke muscle memory for anyone who had been
-- using LazyVim before installing this. Nothing caught it -- the menu sweep
-- only checks that an advertised key *is* mapped, not whose it was.
local H = ...

---Keys LazyVim binds directly in its own config, as lhs -> desc.
---
---Read out of the source rather than the live keymap, because the live keymap
---is the result *after* this layer has had its say -- which is precisely what
---is under test.
local function lazyvim_keymaps()
  local file = vim.api.nvim_get_runtime_file("lua/lazyvim/config/keymaps.lua", false)[1]
  H.ok(file, "LazyVim's keymaps.lua should be on the runtimepath")
  local text = table.concat(vim.fn.readfile(file), "\n")

  local out = {}
  for args in text:gmatch("map(%b())") do
    -- map("n", "<leader>fn", <rhs>, { desc = "New File" })
    local mode, lhs = args:match('^%(%s*"([^"]*)"%s*,%s*"([^"]*)"')
    if mode and lhs and lhs:match("^<leader>") then
      local desc = args:match('desc%s*=%s*"([^"]*)"')
      if mode:find("n") then
        out[lhs] = desc or "(no desc)"
      end
    end
  end
  return out
end

---Leader keys bound by the LazyVim *extras* this layer imports, as lhs -> desc.
---
---Added after the database commands were nearly put on <leader>d*, which is the
---debugger's whole namespace -- bound in an extra, so reading only
---config/keymaps.lua would have missed all five collisions.
local function lazyvim_extra_keymaps()
  local out = {}
  local root = _G.KEBAB_TEST.root
  local declared = {}
  for _, spec in ipairs(dofile(root .. "/lua/kebab/plugins/extras.lua")) do
    if spec.import then
      declared[#declared + 1] = spec.import
    end
  end
  for _, name in ipairs(declared) do
    local base = "lua/" .. name:gsub("%.", "/")
    local file = vim.api.nvim_get_runtime_file(base .. ".lua", false)[1]
      or vim.api.nvim_get_runtime_file(base .. "/init.lua", false)[1]
    if file then
      local text = table.concat(vim.fn.readfile(file), "\n")
      -- keys = { { "<leader>xx", ..., desc = "..." } }
      for entry in text:gmatch("{%s*\"(<leader>[^\"]*)\"(.-)}") do
        local _ = entry
      end
      for lhs, rest in text:gmatch('{%s*"(<leader>[^"]*)"(.-)}') do
        local desc = rest:match('desc%s*=%s*"([^"]*)"')
        if desc and out[lhs] == nil then
          out[lhs] = desc
        end
      end
    end
  end
  return out
end

local function norm(lhs)
  local leader = (vim.g.mapleader == " " or vim.g.mapleader == nil) and " " or vim.g.mapleader
  return vim.api.nvim_replace_termcodes((lhs:gsub("<leader>", leader)), true, true, true)
end

local function live_keymaps()
  local out = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    out[norm(m.lhs)] = m.desc or m.rhs or "?"
  end
  return out
end

-- Overrides this layer makes on purpose. Each needs a reason, and each is
-- checked for *still being* an override -- so one that upstream drops shows up
-- here instead of lingering as a stale excuse.
local INTENTIONAL = {
  -- LazyVim's sql extra binds <leader>D straight to DBUIToggle. This layer
  -- needs <leader>D as a prefix instead, because the database commands cannot
  -- live under <leader>d* -- that is the debugger's entire namespace -- and a
  -- which-key group prefix cannot also be a mapping. The toggle moved to
  -- <leader>DD.
  ["<leader>D"] = "needed as the database group prefix; the toggle is <leader>DD",
}

H.describe("LazyVim's own keymaps", function()
  local lazyvim = lazyvim_keymaps()
  local live = live_keymaps()

  H.it("were parsed out of the source", function()
    local n = vim.tbl_count(lazyvim)
    H.ok(n >= 20, "expected to find LazyVim's leader keymaps, found " .. n)
    H.eq("New File", lazyvim["<leader>fn"], "the one that was displaced should be in there")
  end)

  H.it("are not displaced by this layer", function()
    local displaced = {}
    for lhs, desc in pairs(lazyvim) do
      local actual = live[norm(lhs)]
      -- A key LazyVim defines should still describe what LazyVim says it does.
      -- A missing one is fine: lazily-defined keys are not all registered yet.
      if actual ~= nil and desc ~= "(no desc)" and actual ~= desc and not INTENTIONAL[lhs] then
        displaced[#displaced + 1] = ("%s: LazyVim says %q, it is now %q")
          :format(lhs, desc, tostring(actual))
      end
    end
    table.sort(displaced)
    H.eq({}, displaced,
      "add the key to INTENTIONAL with a reason if the override is deliberate")
  end)

  H.it("keeps <leader>fn as plain New File", function()
    -- Named explicitly because this is the one that regressed.
    H.eq("New File", live[norm("<leader>fn")])
  end)

  H.it("has the template picker on the shifted key instead", function()
    H.eq("New File from Template", live[norm("<leader>fN")])
  end)

  H.it("every INTENTIONAL entry is really still an override", function()
    -- Checked against both sources: <leader>D is bound by the sql *extra*, not
    -- by config/keymaps.lua, so looking at one would call a live override stale.
    local extras = lazyvim_extra_keymaps()
    for lhs, reason in pairs(INTENTIONAL) do
      H.ok(lazyvim[lhs] or extras[lhs],
        ("%s is listed as an intentional override (%s) but nothing upstream binds it any more")
          :format(lhs, reason))
    end
  end)
end)

H.describe("LazyVim's extras' keymaps", function()
  local extras = lazyvim_extra_keymaps()
  local live = live_keymaps()

  H.it("were parsed out of the extras this layer imports", function()
    local n = vim.tbl_count(extras)
    H.ok(n >= 20, "expected to find the extras' leader keys, found " .. n)
    H.eq("Toggle Breakpoint", extras["<leader>db"], "the debugger's keys should be in there")
  end)

  H.it("are not displaced by this layer", function()
    local displaced = {}
    for lhs, desc in pairs(extras) do
      local actual = live[norm(lhs)]
      if actual ~= nil and actual ~= desc and not INTENTIONAL[lhs] then
        displaced[#displaced + 1] = ("%s: the extra says %q, it is now %q"):format(lhs, desc, tostring(actual))
      end
    end
    table.sort(displaced)
    H.eq({}, displaced, "add the key to INTENTIONAL with a reason if deliberate")
  end)

  H.it("keeps the whole debugger namespace", function()
    -- The database commands were nearly put here; five would have collided.
    for _, k in ipairs({ "<leader>da", "<leader>db", "<leader>dc", "<leader>dt", "<leader>dp", "<leader>de" }) do
      local actual = live[norm(k)]
      if actual ~= nil then
        H.falsy(actual:match("[Cc]onnection") or actual:match("[Dd]atabase") or actual:match("Tables"),
          ("%s is the debugger's, but is now %q"):format(k, tostring(actual)))
      end
    end
  end)

  H.it("puts the database commands under <leader>D instead", function()
    for k, want in pairs({
      ["<leader>DD"] = "Database Explorer",
      ["<leader>Da"] = "Add Connection",
      ["<leader>Dt"] = "Browse Tables",
      ["<leader>Dq"] = "New SQL Console",
    }) do
      H.eq(want, live[norm(k)], k .. " should be the database command")
    end
  end)
end)

H.describe("the layer's own keys", function()
  local live = live_keymaps()

  H.it("are all mapped", function()
    for _, pair in ipairs({
      { "<leader>pn", "New Project" },
      { "<leader>po", "Open Project" },
      { "<leader>pr", "Restore Session" },
      { "<leader>pk", "Keymap Cheatsheet" },
      { "<leader>pd", "Add Dependency" },
      { "<leader>pf", "Generate Project File" },
      { "<leader>cg", "Generate Code" },
      { "<leader>fN", "New File from Template" },
      { "<leader>fS", "New Scratch File" },
      { "<leader>fs", "Open Scratch File" },
      { "<leader>or", "Run Configuration" },
      { "<leader>oe", "Edit Run Configurations" },
    }) do
      H.eq(pair[2], live[norm(pair[1])], pair[1] .. " should be the layer's")
    end
  end)

  H.it("do not collide with each other", function()
    -- Two specs binding the same key means one silently wins.
    --
    -- The spec list is read off disk rather than written here: it used to name
    -- four files, and by then five declared keys -- sql.lua was never checked.
    local dir = _G.KEBAB_TEST.root .. "/lua/kebab/plugins"
    local seen = {}
    local files_with_keys = 0
    for _, path in ipairs(vim.fn.glob(dir .. "/*.lua", false, true)) do
      local name = vim.fn.fnamemodify(path, ":t:r")
      local ok, spec = pcall(dofile, path)
      H.ok(ok, path .. " should load: " .. tostring(spec))
      local had_keys = false
      for _, entry in ipairs(type(spec) == "table" and spec or {}) do
        for _, key in ipairs(type(entry) == "table" and entry.keys or {}) do
          local lhs = type(key) == "table" and key[1] or key
          -- `{ lhs, false }` REMOVES an inherited key rather than binding one,
          -- so two specs disabling the same key is not a collision.
          local removes = type(key) == "table" and key[2] == false
          if type(lhs) == "string" and lhs ~= "" and not removes then
            had_keys = true
            local id = lhs .. "|" .. tostring(type(key) == "table" and key.ft or "")
            H.falsy(seen[id], ("%s is bound twice (%s and %s)"):format(lhs, tostring(seen[id]), name))
            seen[id] = name
          end
        end
      end
      if had_keys then
        files_with_keys = files_with_keys + 1
      end
    end
    H.ok(files_with_keys >= 5, "expected several specs to declare keys, found " .. files_with_keys)
    H.ok(vim.tbl_count(seen) >= 20, "and plenty of keys, found " .. vim.tbl_count(seen))
  end)
end)
