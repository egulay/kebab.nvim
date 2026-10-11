-- In-Neovim test entry point. Started by tests/run.sh.
--
-- Loads the user's real config (so LazyVim, Snacks and the 80-odd plugins are
-- the ones that actually ship), waits for lazy.nvim to settle, then runs each
-- spec file. Exits non-zero if anything failed, so CI and `&&` chains work.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local H = dofile(root .. "/tests/harness.lua")

_G.KEBAB_TEST = { root = root, H = H }

-- Never run from the project directory: a spec that writes a file must not be
-- able to land in the repo.
local sandbox = H.tmpdir("cwd")
vim.cmd("cd " .. vim.fn.fnameescape(sandbox))

-- lazy.nvim installs/loads asynchronously; VeryLazy is what brings in the
-- globals the menus reference.
local function settle()

-- Everything vim.notify received while the editor started, kept separate from
-- the running log: specs deliberately provoke warnings of their own, so the
-- "startup is silent" assertion needs a snapshot rather than a growing list.
H.startup_notifications = vim.deepcopy(H.notify_log)
H.notify_log = {}
  local ok = vim.wait(60000, function()
    return package.loaded["lazy"] ~= nil and _G.LazyVim ~= nil
  end, 100)
  if not ok then
    io.write("FATAL: lazy.nvim / LazyVim did not load within 60s\n")
    vim.cmd("cq 2")
  end
  -- let VeryLazy consumers finish registering
  vim.wait(2000, function() return _G.Snacks ~= nil end, 50)
  vim.wait(300, function() return false end, 50)

  -- VeryLazy is fired off UIEnter, which never happens with --headless. Without
  -- it most of LazyVim's own keymaps (<C-s>, <leader>qq, <leader>uz, the git
  -- ones) are never set, so a test asking "is this shortcut real?" would get a
  -- misleading no. Fire it by hand to get the editor a user would actually see.
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "VeryLazy", modeline = false })
  vim.wait(2000, function()
    return vim.fn.maparg(vim.api.nvim_replace_termcodes("<C-s>", true, true, true), "n") ~= ""
  end, 50)
  vim.wait(300, function() return false end, 50)
  -- Must happen before any spec touches vim.notify. See the comment on
  -- H.install_notify_baseline: restoring LazyVim's queueing stand-in makes its
  -- replay feed itself until Lua overflows.
  H.install_notify_baseline()
end

settle()

local only = vim.env.KEBAB_TEST_ONLY
local files = vim.fn.glob(root .. "/tests/spec/*_spec.lua", false, true)
table.sort(files)

io.write("\nkebab.nvim tests  (nvim " .. tostring(vim.version()) .. ")\n")
io.write("scratch: " .. H.scratch_root .. "\n\n")

local ran = 0
for _, file in ipairs(files) do
  local name = vim.fn.fnamemodify(file, ":t:r")
  if not only or name:find(only, 1, true) then
    ran = ran + 1
    io.write("── " .. name .. "\n")
    local chunk, lerr = loadfile(file)
    if not chunk then
      H.results.fail = H.results.fail + 1
      H.results.failures[#H.results.failures + 1] = { label = name, err = lerr }
      io.write("  FAIL could not load spec: " .. tostring(lerr) .. "\n")
    else
      local ok, rerr = pcall(chunk, H)
      if not ok then
        H.results.fail = H.results.fail + 1
        H.results.failures[#H.results.failures + 1] = { label = name .. " (file)", err = rerr }
        io.write("  FAIL spec aborted: " .. tostring(rerr) .. "\n")
      end
    end
    -- Leave the next spec a clean editor rather than whatever this one left
    -- open. See H.reset_editor.
    pcall(H.reset_editor)
    io.write("\n")
  end
end

if ran == 0 then
  io.write("no specs matched " .. tostring(only) .. "\n")
end

local r = H.report()
vim.cmd(r.fail > 0 and "cq 1" or "qa!")
