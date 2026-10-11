-- The LazyVim extras this layer depends on.
--
-- Declared here rather than in the user's lazyvim.json so that installing the
-- layer is enough: a user should not have to hand-edit their own config for
-- Java, Flutter or the rest to appear.
--
-- Split in two on purpose. The editor and core extras below belong to the layer
-- itself -- they are what makes it an IDE regardless of what you write in it.
-- The *language* extras come from lua/kebab/languages/, so adding Go means
-- adding one file there rather than editing this list and four others.
--
-- vim.g.lazyvim_check_order = false is set here too. LazyVim warns that the
-- import order is wrong because the last extra is imported after a module called
-- `plugins`, which is true: the user's own ~/.config/nvim/lua/plugins is module
-- 5 and these extras arrive at 7+, since this layer imports them itself instead
-- of making the user list two dozen of them. What the check protects still
-- holds -- lazy imports a directory in sorted order, so `extras.lua` is
-- processed before flutter.lua, java.lua, python.lua and ui.lua, and their opts
-- merge on top. tests/spec/config_spec.lua asserts that rather than trusting
-- this comment.
--
-- The residual difference from LazyVim's preferred layout is that the user's own
-- lua/plugins/*.lua files are imported before these extras instead of after.
vim.g.lazyvim_python_lsp = "basedpyright"
vim.g.lazyvim_python_ruff = "ruff"
vim.g.lazyvim_check_order = false

-- LazyVim gives dap.core, test.core and lang.typescript a higher load priority
-- than the rest (lazyvim/plugins/extras.lua), so they are imported first.
local FIRST = {
  "lazyvim.plugins.extras.dap.core",
  "lazyvim.plugins.extras.lang.typescript",
  "lazyvim.plugins.extras.test.core",
}

-- Editor capability, not language support: these are the layer's own.
local CORE = {
  "lazyvim.plugins.extras.ai.claudecode",
  "lazyvim.plugins.extras.editor.aerial",
  "lazyvim.plugins.extras.editor.illuminate",
  "lazyvim.plugins.extras.editor.inc-rename",
  "lazyvim.plugins.extras.editor.neo-tree",
  "lazyvim.plugins.extras.editor.overseer",
  "lazyvim.plugins.extras.editor.refactoring",
  "lazyvim.plugins.extras.util.project",
  "lazyvim.plugins.extras.util.rest",
}

local specs, seen = {}, {}
local function add(name)
  if not seen[name] then
    seen[name] = true
    specs[#specs + 1] = { import = name }
  end
end

for _, name in ipairs(FIRST) do
  add(name)
end
for _, name in ipairs(CORE) do
  add(name)
end
-- Whatever the languages ask for. Requiring the registry here is safe: it has
-- no dependencies of its own, which matters because this file is evaluated
-- while lazy.nvim is still building its spec.
for _, name in ipairs(require("kebab.registry").extras()) do
  add(name)
end

return specs
