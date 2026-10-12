-- Menu-bar style menu for the editor, opened with <RightMouse> or <leader>M.
-- `rtxt` shows each entry's keybinding, the way a graphical menu does.
--
-- Every `cmd` here is either a plain Ex command string or an action built by
-- kebab.menus.action. Nothing else: the action builders carry a descriptor that
-- tests/spec/menu_editor_spec.lua uses to check each target still exists, and an
-- opaque closure would silently drop out of that sweep. See action.lua.
local A = require("kebab.menus.action")

-- Tests: neotest has no Java adapter, so LazyVim's java extra binds
-- <leader>tr/tt/tT to jdtls.dap instead. These entries advertise those same
-- keys, so they have to dispatch the same way -- otherwise the menu runs
-- neotest in a Java buffer and reports "no tests found" on a file full of them.
local TEST_BACKENDS = {
  java = {
    module = "jdtls.dap",
    nearest = { "test_nearest_method", {} },
    file = { "test_class", {} },
    pick = { "pick_test", {} },
  },
  default = {
    module = "neotest",
    nearest = { "run.run", {} },
    file = { "run.run", { "%:p" } },
    pick = { "run.run", { { suite = true } } },
  },
}

local function backend_for(ft)
  return TEST_BACKENDS[ft] or TEST_BACKENDS.default
end

local function run_test(scope, label)
  local function dispatch()
    local backend = backend_for(vim.bo.filetype)
    local path, args = backend[scope][1], backend[scope][2]
    local ok, mod = pcall(require, backend.module)
    if not ok then
      return vim.notify(backend.module .. " is not available", vim.log.levels.WARN)
    end
    local target, missing = A.resolve(mod, path)
    if not target or not A.callable(target) then
      return vim.notify(("%s.%s not found (no .%s)"):format(backend.module, path, tostring(missing)), vim.log.levels.WARN)
    end
    -- "%:p" is a placeholder resolved now, not when the menu was built
    local call = vim.tbl_map(function(a)
      return a == "%:p" and vim.fn.expand("%:p") or a
    end, args)
    local called, err = pcall(target, unpack(call, 1, #args))
    if not called then
      vim.notify(("%s.%s failed: %s"):format(backend.module, path, tostring(err)), vim.log.levels.WARN)
    end
  end

  -- The sweep cannot click this, so it checks every backend resolves instead.
  local function check()
    local problems = {}
    for ft, backend in pairs(TEST_BACKENDS) do
      local ok, mod = pcall(require, backend.module)
      if not ok then
        -- jdtls is only present when the java extra is enabled; not a fault
        if ft ~= "java" then
          problems[#problems + 1] = backend.module .. " does not load"
        end
      else
        local target = A.resolve(mod, backend[scope][1])
        if not target or not A.callable(target) then
          problems[#problems + 1] = ("%s.%s missing"):format(backend.module, backend[scope][1])
        end
      end
    end
    if #problems > 0 then
      return false, table.concat(problems, "; ")
    end
    return true
  end

  return A.custom(label, dispatch, check)
end

local project = {
  { name = "New Project...", cmd = A.ex("IdeNewProject"), rtxt = "<leader>pn" },
  { name = "Scaffold Into This Folder...", cmd = A.ex("IdeInitHere"), rtxt = ":IdeInitHere" },
  { name = "Open Project...", cmd = A.ex("IdeOpenProject"), rtxt = "<leader>po" },
  { name = "separator" },
  { name = "Add Dependency...", cmd = A.ex("IdeAddDependency"), rtxt = "<leader>pd" },
  { name = "Generate Project File...", cmd = A.ex("IdeProjectFile"), rtxt = "<leader>pf" },
  { name = "separator" },
  { name = "Recent Projects", cmd = A.g("Snacks", "picker.projects"), rtxt = "<leader>fp" },
  { name = "Restore Session", cmd = A.mod("persistence", "load"), rtxt = "<leader>pr" },
  { name = "separator" },
  -- Was an absolute path into ~/.config/nvim/IDE-CHEATSHEET.md, which has never
  -- existed: the file ships with this repo and is found on the runtimepath.
  { name = "Keymap Cheatsheet", cmd = A.ex("IdeCheatsheet"), rtxt = "<leader>pk" },
}

local file = {
  { name = "New File", cmd = "enew", rtxt = ":enew" },
  { name = "New File from Template...", cmd = A.ex("IdeNewFile"), rtxt = "<leader>fN" },
  { name = "New Scratch File...", cmd = A.ex("IdeScratch"), rtxt = "<leader>fS" },
  { name = "Open Scratch File...", cmd = A.ex("IdeScratchList"), rtxt = "<leader>fs" },
  { name = "Open File...", cmd = A.pick("files"), rtxt = "<leader>ff" },
  { name = "Recent Files", cmd = A.pick("oldfiles"), rtxt = "<leader>fr" },
  { name = "Open Project...", cmd = A.g("Snacks", "picker.projects"), rtxt = "<leader>fp" },
  { name = "separator" },
  { name = "Save", cmd = "write", rtxt = "<C-s>" },
  { name = "Save All", cmd = "wall", rtxt = ":wa" },
  { name = "separator" },
  { name = "Close File", cmd = A.g("Snacks", "bufdelete"), rtxt = "<leader>bd" },
  { name = "Exit", cmd = "qa", rtxt = "<leader>qq" },
}

local edit = {
  { name = "Undo", cmd = "undo", rtxt = "u" },
  { name = "Redo", cmd = "redo", rtxt = "<C-r>" },
  { name = "separator" },
  { name = "Select All", cmd = "normal! ggVG", rtxt = "ggVG" },
  { name = "Copy Whole File", cmd = "%y+", rtxt = ":%y+" },
  { name = "separator" },
  { name = "Find in File", cmd = A.g("Snacks", "picker.lines"), rtxt = "<leader>sb" },
  { name = "Find in Project", cmd = A.pick("live_grep"), rtxt = "<leader>/" },
  { name = "Replace in Project", cmd = A.mod("grug-far", "open"), rtxt = "<leader>sr" },
  { name = "separator" },
  -- The discoverability half of the brief: everything reachable by name, the
  -- way a command palette is, for people who would rather type than aim.
  { name = "Command Palette...", cmd = A.g("Snacks", "picker.commands"), rtxt = "<leader>sC" },
  { name = "Search Keymaps...", cmd = A.g("Snacks", "picker.keymaps"), rtxt = "<leader>sk" },
}

local code = {
  -- A full graphical IDE opens a popup list here, so a filetype-aware picker is
  -- the
  -- faithful equivalent -- and the only honest one: a static submenu of the
  -- Java generators would be dead in every other buffer.
  { name = "Generate...", cmd = A.ex("IdeGenerate"), rtxt = "<leader>cg" },
  { name = "separator" },
  { name = "Code Action", cmd = A.lsp("code_action"), rtxt = "<leader>ca" },
  { name = "Reformat Code", cmd = A.g("LazyVim", "format", { force = true }), rtxt = "<leader>cf" },
  { name = "Rename Symbol", cmd = A.lsp("rename"), rtxt = "<leader>cr" },
  { name = "separator" },
  { name = "Go to Definition", cmd = A.lsp("definition"), rtxt = "gd" },
  { name = "Go to Implementation", cmd = A.lsp("implementation"), rtxt = "gI" },
  { name = "Find Usages", cmd = A.lsp("references"), rtxt = "gr" },
  { name = "separator" },
  { name = "File Structure", cmd = A.ex("AerialToggle", { plugin = "aerial.nvim" }), rtxt = "<leader>cs" },
  { name = "Problems", cmd = A.ex("Trouble diagnostics toggle", { plugin = "trouble.nvim" }), rtxt = "<leader>xx" },
}

local run = {
  { name = "Run Test at Cursor", cmd = run_test("nearest", "run nearest test"), rtxt = "<leader>tr" },
  { name = "Run Tests in File", cmd = run_test("file", "run tests in file"), rtxt = "<leader>tt" },
  -- Not "Run Test..." -- the ellipsis promised a dialog, and only Java gets
  -- one. <leader>tT is "Run All Test Files" in LazyVim's neotest keys, and in
  -- a Java buffer jdtls owns the key and offers a picker instead (CLAUDE.md:
  -- neotest has no Java adapter here). The name now describes what happens in
  -- every filetype but Java, and the label says what Java does.
  {
    name = "Run All Tests",
    cmd = run_test("pick", "run the whole suite; jdtls offers a picker in Java"),
    rtxt = "<leader>tT",
  },
  { name = "Test Summary", cmd = A.mod("neotest", "summary.toggle"), rtxt = "<leader>ts" },
  { name = "separator" },
  { name = "Toggle Breakpoint", cmd = A.mod("dap", "toggle_breakpoint"), rtxt = "<leader>db" },
  { name = "Debug / Continue", cmd = A.mod("dap", "continue"), rtxt = "<leader>dc" },
  { name = "Step Over", cmd = A.mod("dap", "step_over"), rtxt = "<leader>dO" },
  { name = "Step Into", cmd = A.mod("dap", "step_into"), rtxt = "<leader>di" },
  { name = "Toggle Debug UI", cmd = A.mod("dapui", "toggle"), rtxt = "<leader>du" },
  { name = "separator" },
  {
    name = "Run Configurations",
    items = {
      { name = "Run Configuration...", cmd = A.ex("IdeRunConfig"), rtxt = "<leader>or" },
      { name = "Edit Run Configurations...", cmd = A.ex("IdeRunConfigEdit"), rtxt = "<leader>oe" },
      { name = "separator" },
      { name = "Run Task...", cmd = A.ex("OverseerRun", { plugin = "overseer.nvim" }), rtxt = "<leader>oo" },
      { name = "Task List", cmd = A.ex("OverseerToggle!", { plugin = "overseer.nvim" }), rtxt = "<leader>ow" },
      { name = "Task Action...", cmd = A.ex("OverseerTaskAction", { plugin = "overseer.nvim" }), rtxt = "<leader>ot" },
    },
  },
  {
    name = "Flutter",
    items = {
      { name = "Run", cmd = A.ex("FlutterRun", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fr" },
      { name = "Hot Reload", cmd = A.ex("FlutterReload", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fh" },
      { name = "Hot Restart", cmd = A.ex("FlutterRestart", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>FR" },
      { name = "Quit", cmd = A.ex("FlutterQuit", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fq" },
      { name = "separator" },
      { name = "Devices", cmd = A.ex("FlutterDevices", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fd" },
      { name = "Emulators", cmd = A.ex("FlutterEmulators", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fe" },
      { name = "Dev Log", cmd = A.ex("FlutterLogToggle", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fl" },
      { name = "Pub Get", cmd = A.ex("FlutterPubGet", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fp" },
      { name = "Outline", cmd = A.ex("FlutterOutlineToggle", { plugin = "flutter-tools.nvim" }), rtxt = "<leader>Fo" },
    },
  },
}

local git = {
  { name = "Lazygit", cmd = A.g("Snacks", "lazygit"), rtxt = "<leader>gg" },
  { name = "separator" },
  { name = "Stage Hunk", cmd = A.mod("gitsigns", "stage_hunk"), rtxt = "<leader>ghs" },
  { name = "Unstage Hunk", cmd = A.mod("gitsigns", "undo_stage_hunk"), rtxt = "<leader>ghu" },
  { name = "Reset Hunk", cmd = A.mod("gitsigns", "reset_hunk"), rtxt = "<leader>ghr" },
  { name = "Preview Hunk", cmd = A.mod("gitsigns", "preview_hunk_inline"), rtxt = "<leader>ghp" },
  { name = "separator" },
  { name = "Stage Whole File", cmd = A.mod("gitsigns", "stage_buffer"), rtxt = "<leader>ghS" },
  { name = "Revert File (discard changes)", cmd = A.mod("gitsigns", "reset_buffer"), rtxt = "<leader>ghR" },
  { name = "separator" },
  -- ghb, not ghB: ghB is gitsigns' Blame *Buffer*, a whole-file split, while
  -- this entry is the cursor line's popup.
  { name = "Blame Line", cmd = A.mod("gitsigns", "blame_line", { full = true }), rtxt = "<leader>ghb" },
  { name = "Diff This File", cmd = A.mod("gitsigns", "diffthis"), rtxt = "<leader>ghd" },
  -- gf, not gl: gl is the repo-wide Git Log, this entry is the current file's
  -- history.
  { name = "File History", cmd = A.g("Snacks", "picker.git_log_file"), rtxt = "<leader>gf" },
  { name = "separator" },
  { name = "Diff View (working tree)", cmd = A.ex("DiffviewOpen", { plugin = "diffview.nvim" }), rtxt = "<leader>gv" },
  { name = "Diff View (file history)", cmd = A.ex("DiffviewFileHistory %", { plugin = "diffview.nvim" }), rtxt = "<leader>gV" },
  { name = "Close Diff View", cmd = A.ex("DiffviewClose", { plugin = "diffview.nvim" }), rtxt = "<leader>gq" },
}

local database = {
  { name = "Database Explorer", cmd = A.ex("DBUIToggle", { plugin = "vim-dadbod-ui" }), rtxt = "<leader>DD" },
  { name = "separator" },
  { name = "Add Connection...", cmd = A.ex("IdeDbAdd"), rtxt = "<leader>Da" },
  { name = "Attach Connection to Buffer...", cmd = A.ex("IdeDbConnect"), rtxt = "<leader>Dc" },
  { name = "Test Connection", cmd = A.ex("IdeDbPing"), rtxt = "<leader>Dp" },
  { name = "separator" },
  { name = "Browse Tables...", cmd = A.ex("IdeDbTables"), rtxt = "<leader>Dt" },
  { name = "New SQL Console", cmd = A.ex("IdeDbConsole"), rtxt = "<leader>Dq" },
  { name = "separator" },
  { name = "Run Statement", cmd = A.ex("IdeDbRun"), rtxt = "<C-CR>" },
  { name = "Run Whole Buffer", cmd = A.ex("IdeDbRunAll"), rtxt = ":IdeDbRunAll" },
  { name = "separator" },
  { name = "Next Page of Rows", cmd = A.ex("IdeDbNextPage"), rtxt = "]p" },
  { name = "Previous Page of Rows", cmd = A.ex("IdeDbPrevPage"), rtxt = "[p" },
  { name = "First Page of Rows", cmd = A.ex("IdeDbFirstPage"), rtxt = "[P" },
  { name = "Re-run This Page", cmd = A.ex("IdeDbRefreshPage"), rtxt = "R" },
  { name = "separator" },
  { name = "Edit Connections File", cmd = A.ex("IdeDbEdit"), rtxt = "<leader>De" },
  { name = "Remove Connection...", cmd = A.ex("IdeDbRemove"), rtxt = ":IdeDbRemove" },
}

local view = {
  { name = "Project Tree", cmd = A.ex("Neotree toggle", { plugin = "neo-tree.nvim" }), rtxt = "<leader>e" },
  { name = "File Structure", cmd = A.ex("AerialToggle", { plugin = "aerial.nvim" }), rtxt = "<leader>cs" },
  { name = "Problems", cmd = A.ex("Trouble diagnostics toggle", { plugin = "trouble.nvim" }), rtxt = "<leader>xx" },
  { name = "separator" },
  { name = "Terminal", cmd = A.g("Snacks", "terminal"), rtxt = "<C-/>" },
  { name = "Zen Mode", cmd = A.g("Snacks", "zen"), rtxt = "<leader>uz" },
  { name = "separator" },
  { name = "Follow External Edits", cmd = A.ex("IdeFollow"), rtxt = "<leader>uf" },
}

-- Shortcuts are declared canonically above -- `<leader>DD` -- because that is
-- what menu_shortcuts_spec checks against the real mappings. What goes on
-- screen is what a person presses: "Space D D". kebab.keys is the one place
-- that converts, so the two cannot drift.
return require("kebab.keys").humanise({
  { name = "Project", items = project },
  { name = "File", items = file },
  { name = "Edit", items = edit },
  { name = "Code", items = code },
  { name = "Run", items = run },
  { name = "Git", items = git },
  { name = "Database", items = database },
  { name = "View", items = view },
})
